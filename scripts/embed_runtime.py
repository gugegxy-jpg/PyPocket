"""Xcode 构建阶段：标准库复制、原生扩展转 Framework，并生成 .fwork 索引。"""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = "3.15"


def select_layout(framework: Path, platform: str, arch: str) -> tuple[Path, Path]:
    metadata = plistlib.loads((framework / "Info.plist").read_bytes())
    simulator = platform == "iphonesimulator"
    for library in metadata["AvailableLibraries"]:
        if library["SupportedPlatform"] != "ios" or arch not in library["SupportedArchitectures"]:
            continue
        if (library.get("SupportedPlatformVariant") == "simulator") != simulator:
            continue
        slice_path = framework / library["LibraryIdentifier"]
        pure_candidates = [framework / "lib" / f"python{VERSION}", slice_path / "lib" / f"python{VERSION}"]
        binary_candidates = [slice_path / f"lib-{arch}" / f"python{VERSION}" / "lib-dynload",
                             slice_path / "lib" / f"python{VERSION}" / "lib-dynload"]
        pure = next((path for path in pure_candidates if (path / "encodings").is_dir()), None)
        binary = next((path for path in binary_candidates if path.is_dir()), None)
        if pure and binary:
            return pure, binary
    raise RuntimeError(f"Python 支持包中找不到 {platform}/{arch} 的标准库布局")


def ignored(directory, names):
    return [name for name in names if name in {"test", "tests", "__pycache__", "idlelib", "tkinter", "turtledemo", "ensurepip", "lib-dynload"}
            or name.endswith((".pyc", ".a", ".so")) or name.startswith("config-")]


def dependencies(binary: Path) -> list[str]:
    lines = subprocess.check_output(["xcrun", "otool", "-L", str(binary)], text=True).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines if line.strip()]


def embed(app: Path, platform: str, arch: str, native_tools: bool = True) -> None:
    framework = ROOT / "Vendor" / "Python.xcframework"
    pure, binaries = select_layout(framework, platform, arch)
    destination = app / "python" / "lib" / f"python{VERSION}"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(pure, destination, ignore=ignored)
    dynamic = destination / "lib-dynload"
    dynamic.mkdir()
    frameworks = app / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    # 仅清理本脚本拥有的自动生成扩展，避免旧模块混入增量构建。
    for old in frameworks.glob("pypocket_*.framework"):
        shutil.rmtree(old)
    count = 0
    for source in sorted(binaries.glob("*.so")):
        module = source.name.split(".", 1)[0]
        if module.startswith("_test") or module in {"_ctypes_test", "xxlimited", "xxlimited_35"}:
            continue
        name = "pypocket_" + module
        folder = frameworks / f"{name}.framework"
        folder.mkdir()
        target = folder / name
        shutil.copy2(source, target)
        target.chmod(0o755)
        identifier = "app.pypocket.runtime." + re.sub(r"[^a-zA-Z0-9.-]", "-", module)
        info = {
            "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
            "CFBundleName": name, "CFBundlePackageType": "FMWK",
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1", "MinimumOSVersion": "17.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator" if platform == "iphonesimulator" else "iPhoneOS"],
        }
        (folder / "Info.plist").write_bytes(plistlib.dumps(info))
        marker = dynamic / (source.name[:-3] + ".fwork")
        marker.write_text(target.relative_to(app).as_posix() + "\n", encoding="utf-8")
        (folder / f"{name}.origin").write_text(marker.relative_to(app).as_posix() + "\n", encoding="utf-8")
        if native_tools:
            identity = subprocess.check_output(["xcrun", "otool", "-D", str(target)], text=True).splitlines()
            if len(identity) > 1:
                subprocess.run(["xcrun", "install_name_tool", "-id", f"@rpath/{name}.framework/{name}", str(target)], check=True)
            for dependency in dependencies(target):
                if "libpython" in dependency:
                    subprocess.run(["xcrun", "install_name_tool", "-change", dependency,
                                    "@rpath/Python.framework/Python", str(target)], check=True)
                elif dependency.startswith(("/Users/", "/private/", "/opt/", "/usr/local/")):
                    raise RuntimeError(f"扩展仍引用构建机路径：{dependency}")
            if os.environ.get("CODE_SIGNING_ALLOWED", "YES") != "NO":
                signer = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
                subprocess.run(["codesign", "--force", "--sign", signer, "--timestamp=none", str(folder)], check=True)
        count += 1
    if count == 0:
        raise RuntimeError("没有打包任何 Python 原生扩展")
    # CPython 的 OpenSSL 不自动读取 iOS 钥匙串，随包提供经过校验的 CA 根证书。
    certificates = ROOT / "Vendor" / "cacert.pem"
    if not certificates.exists():
        raise RuntimeError("缺少 CA 证书包，请先执行 prepare_certificates.py")
    shutil.copy2(certificates, app / "cacert.pem")
    license_parts = ["PyPocket 运行时第三方许可\n\nPython Apple Support\nhttps://github.com/beeware/Python-Apple-support\n",
                     (ROOT / "Vendor" / "VERSIONS").read_text(encoding="utf-8"),
                     (pure / "LICENSE.txt").read_text(encoding="utf-8"),
                     "\nCertifi / Mozilla CA Bundle — MPL-2.0\nhttps://github.com/certifi/python-certifi\n",
                     (ROOT / "Vendor" / "certifi-LICENSE.txt").read_text(encoding="utf-8")]
    notice = ROOT / "Vendor" / "native-licenses.txt"
    if notice.exists():
        license_parts.append(notice.read_text(encoding="utf-8"))
    (app / "runtime-licenses.txt").write_text("\n\n".join(license_parts), encoding="utf-8")
    print(f"已打包 Python {VERSION} 标准库与 {count} 个原生扩展（{platform}/{arch}）。")


if __name__ == "__main__":
    platform = os.environ["PLATFORM_NAME"]
    arch = os.environ.get("CURRENT_ARCH", "")
    if arch not in ("arm64", "x86_64"):
        arch = os.environ.get("ARCHS", "arm64").split()[0]
    product = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    embed(product, platform, arch)
