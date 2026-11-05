"""项目导入边界：只解包数据，不执行下载内容，不安装依赖。"""
from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import unicodedata
import uuid
import zipfile
from datetime import datetime, timezone

MAX_SOURCE = 50 * 1024 * 1024
MAX_EXPANDED = 150 * 1024 * 1024
MAX_ENTRIES = 3000


def _relative_name(name: str) -> PurePosixPath:
    name = unicodedata.normalize("NFC", name)
    if "\\" in name or "\x00" in name or ":" in name:
        raise ValueError("压缩包包含不安全的文件路径")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("压缩包试图写入项目目录之外")
    if any(part in ("", ".") for part in name.rstrip("/").split("/")):
        raise ValueError("压缩包包含无效路径")
    return path


def extract_project(archive: Path, destination: Path) -> None:
    """拒绝链接、路径穿越、重复覆盖和过量解压；失败由调用方回滚。"""
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) > MAX_ENTRIES:
            raise ValueError("ZIP 文件数量超过 3000 个")
        expanded = 0
        seen: set[str] = set()
        written = 0
        for info in entries:
            # orig_filename 保留被 zipfile 规范化前的原始路径（例如反斜杠与 NUL）。
            path = _relative_name(info.orig_filename)
            if path.parts[0] == "__MACOSX" or path.name == ".DS_Store":
                continue
            key = str(path).casefold()
            if key in seen:
                raise ValueError("ZIP 包含重复或大小写冲突的路径")
            seen.add(key)
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("ZIP 不允许符号链接或特殊文件")
            if info.flag_bits & 1:
                raise ValueError("暂不支持加密 ZIP")
            expanded += info.file_size
            if expanded > MAX_EXPANDED:
                raise ValueError("ZIP 解压大小超过 150 MB")
            if info.file_size > 1024 * 1024 and info.file_size > max(1, info.compress_size) * 300:
                raise ValueError("ZIP 压缩比异常，已拒绝解包")
            target = destination.joinpath(*path.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.open(info) as source, target.open("xb") as output:
                while block := source.read(128 * 1024):
                    written += len(block)
                    if written > MAX_EXPANDED:
                        raise ValueError("实际解压大小超过上限")
                    output.write(block)


def import_project(source_path: str, projects_path: str, display_name: str = "") -> dict:
    source = Path(source_path)
    if not source.is_file() or source.stat().st_size > MAX_SOURCE:
        raise ValueError("导入文件不存在或超过 50 MB")
    suffix = source.suffix.lower()
    if suffix not in (".py", ".zip"):
        raise ValueError("仅支持 .py 和 .zip 文件")
    projects = Path(projects_path)
    projects.mkdir(parents=True, exist_ok=True)
    project_id = str(uuid.uuid4()).upper()
    staging = projects / (".import-" + project_id)
    workspace = staging / "workspace"
    workspace.mkdir(parents=True)
    try:
        if suffix == ".py":
            shutil.copyfile(source, workspace / "main.py")
        else:
            extract_project(source, workspace)
        candidates = sorted(
            str(path.relative_to(workspace).as_posix())
            for path in workspace.rglob("*.py")
            if "__pycache__" not in path.parts
        )
        if not candidates:
            raise ValueError("项目中没有可运行的 .py 文件")
        priorities = {"main.py": 0, "app.py": 1, "server.py": 2, "__main__.py": 3}
        candidates.sort(key=lambda value: (priorities.get(PurePosixPath(value).name, 9), value.count("/"), value))
        metadata = {
            "id": project_id,
            "name": (display_name.strip() or source.stem)[:100],
            "entry": candidates[0],
            "files": candidates,
            "arguments": "[]",
            "environment": "{}",
            "previewPort": 8000,
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }
        (staging / "project.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
        staging.rename(projects / project_id)
        return metadata
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def import_json(request: str) -> str:
    spec = json.loads(request)
    return json.dumps(import_project(spec["source"], spec["projects"], spec.get("name", "")), ensure_ascii=False)
