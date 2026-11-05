"""下载并校验固定版本的 iOS CPython 支持包；不使用浮动 latest。"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "3.15"
BUILD = "b3"
SHA256 = "429080dcfab3778b75bbc6548cbfd754dc943cfc6092a92b72022541ff3212a0"
URL = (
    "https://github.com/beeware/Python-Apple-support/releases/download/"
    f"{VERSION}-{BUILD}/Python-{VERSION}-iOS-support.{BUILD}.tar.gz"
)


def prepare() -> None:
    vendor = ROOT / "Vendor"
    marker = vendor / "runtime-lock.json"
    lock = {"version": VERSION, "build": BUILD, "sha256": SHA256, "url": URL}
    framework = vendor / "Python.xcframework"
    if marker.exists() and framework.exists():
        if json.loads(marker.read_text(encoding="utf-8")) == lock:
            print("CPython 支持包已就绪。")
            return
        raise RuntimeError("Vendor 中存在其他版本，请移走 Vendor 后重新构建。")
    vendor.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="python-runtime-", dir=ROOT) as temp:
        staging = Path(temp)
        archive = staging / "support.tar.gz"
        digest = hashlib.sha256()
        request = urllib.request.Request(URL, headers={"User-Agent": "PyPocket-build/1.0"})
        print(f"下载 {URL}", flush=True)
        with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as out:
            while block := response.read(1024 * 1024):
                digest.update(block)
                out.write(block)
        if digest.hexdigest() != SHA256:
            raise RuntimeError("Python 支持包 SHA-256 不匹配，已拒绝解包。")
        unpacked = staging / "unpacked"
        unpacked.mkdir()
        with tarfile.open(archive, "r:gz") as package:
            package.extractall(unpacked, filter="data")
        candidates = sorted(unpacked.rglob("Python.xcframework"), key=lambda path: len(path.parts))
        if not candidates:
            names = [str(path.relative_to(unpacked)) for path in unpacked.iterdir()]
            raise RuntimeError(f"支持包未包含 Python.xcframework，顶层内容：{names}")
        # 支持包还可能在测试宿主里携带框架引用，优先选顶层的完整框架。
        source = candidates[0]
        if not (source / "Info.plist").is_file():
            raise RuntimeError(f"Python 框架缺少 Info.plist：{source}")
        if framework.exists():
            raise RuntimeError("Vendor/Python.xcframework 已存在但没有匹配的版本记录。")
        shutil.move(str(source), str(framework))
        for name in ("VERSIONS", "LICENSE", "LICENSE.txt"):
            candidate = source.parent / name
            if candidate.exists():
                shutil.copy2(candidate, vendor / name)
        temporary_marker = marker.with_suffix(".tmp")
        temporary_marker.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary_marker, marker)
        print(f"CPython {VERSION}-{BUILD} 支持包校验完成。")


if __name__ == "__main__":
    prepare()
