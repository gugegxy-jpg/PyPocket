"""可在 Windows/macOS 运行的导入边界与解释器调度测试。"""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Resources" / "runtime"))

stop_event = threading.Event()
output: list[str] = []
native = types.ModuleType("_pypocket_native")
native.cancelled = stop_event.is_set
native.write = output.append
sys.modules["_pypocket_native"] = native

import project_io
import pypocket_host


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        temp_root = ROOT / "build" / "test-tmp"
        temp_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=temp_root)
        self.root = Path(self.temp.name)
        self.projects = self.root / "Projects"
        stop_event.clear()
        output.clear()

    def tearDown(self):
        stop_event.clear()
        self.temp.cleanup()

    def archive(self, names):
        source = self.root / "source.zip"
        with zipfile.ZipFile(source, "w") as archive:
            for name, data in names:
                archive.writestr(name, data)
        return source

    def run_source(self, text, **options):
        script = self.root / "main.py"
        script.write_text(text, encoding="utf-8")
        spec = {"workspace": str(self.root), "entry": "main.py", **options}
        return json.loads(pypocket_host.execute_json(json.dumps(spec)))


class ImportTests(WorkspaceTest):
    def test_single_python(self):
        source = self.root / "测试.py"
        source.write_text("print('你好')", encoding="utf-8")
        result = project_io.import_project(str(source), str(self.projects))
        self.assertEqual(result["entry"], "main.py")
        self.assertEqual(result["name"], "测试")
        self.assertTrue((self.projects / result["id"] / "workspace" / "main.py").exists())

    def test_nested_zip_entry(self):
        source = self.archive([("project/util.py", ""), ("project/main.py", "print('hi')")])
        result = project_io.import_project(str(source), str(self.projects))
        self.assertEqual(result["entry"], "project/main.py")
        self.assertEqual(len(result["files"]), 2)

    def test_import_never_executes(self):
        marker = self.root / "executed"
        source = self.root / "source.py"
        source.write_text(f"open({str(marker)!r}, 'w').write('bad')", encoding="utf-8")
        project_io.import_project(str(source), str(self.projects))
        self.assertFalse(marker.exists())

    def test_zip_traversal_and_absolute_paths(self):
        for path in ("../escape.py", "/escape.py", "C:/escape.py", "dir\\escape.py", "a//main.py"):
            with self.subTest(path=path):
                source = self.archive([(path, "print('bad')")])
                if "\\" in path:
                    # Windows 的 ZIP 写入器会把反斜杠转为斜杠，还原原始恶意字节再测试读取端。
                    source.write_bytes(source.read_bytes().replace(path.replace("\\", "/").encode(), path.encode()))
                with self.assertRaises(ValueError):
                    project_io.import_project(str(source), str(self.projects))
                self.assertEqual(list(self.projects.iterdir()), [])

    def test_zip_symlink_rejected(self):
        info = zipfile.ZipInfo("link.py")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        source = self.archive([(info, "../outside.py")])
        with self.assertRaises(ValueError):
            project_io.import_project(str(source), str(self.projects))

    def test_case_collision_rejected(self):
        source = self.archive([("main.py", ""), ("MAIN.py", "")])
        with self.assertRaises(ValueError):
            project_io.import_project(str(source), str(self.projects))

    def test_no_python_rolls_back(self):
        source = self.archive([("image.txt", "hello")])
        with self.assertRaises(ValueError):
            project_io.import_project(str(source), str(self.projects))
        self.assertEqual(list(self.projects.iterdir()), [])

    def test_expanded_and_source_limits(self):
        source = self.archive([("main.py", "x" * 100)])
        with patch.object(project_io, "MAX_EXPANDED", 50), self.assertRaises(ValueError):
            project_io.import_project(str(source), str(self.projects))
        with patch.object(project_io, "MAX_SOURCE", 5), self.assertRaises(ValueError):
            project_io.import_project(str(source), str(self.projects))

    def test_file_parent_conflict_rolls_back(self):
        source = self.archive([("folder", "x"), ("folder/main.py", "print(1)")])
        with self.assertRaises(OSError):
            project_io.import_project(str(source), str(self.projects))
        self.assertEqual(list(self.projects.iterdir()), [])


class ExecutionTests(WorkspaceTest):
    def test_output_arguments_environment_and_restore(self):
        before = (os.getcwd(), list(sys.path), dict(os.environ), sys.stdout, time.sleep)
        result = self.run_source(
            "import os, sys\nprint('你好', sys.argv[1], os.environ['POCKET_TEST'])\n",
            arguments=["参数"], environment={"POCKET_TEST": "值"})
        self.assertEqual(result, {"status": "finished", "exitCode": 0})
        self.assertIn("你好 参数 值", "".join(output))
        self.assertEqual(before, (os.getcwd(), list(sys.path), dict(os.environ), sys.stdout, time.sleep))

    def test_syntax_error_does_not_poison_next_run(self):
        result = self.run_source("if broken syntax")
        self.assertEqual(result["status"], "failed")
        self.assertIn("SyntaxError", "".join(output))
        self.assertEqual(self.run_source("print('next')")["status"], "finished")

    def test_system_exit(self):
        self.assertEqual(self.run_source("raise SystemExit(3)")["exitCode"], 3)
        self.assertEqual(self.run_source("raise SystemExit(0)")["status"], "finished")

    def test_entry_escape_rejected(self):
        with self.assertRaises((ValueError, FileNotFoundError)):
            pypocket_host.execute_json(json.dumps({"workspace": str(self.root), "entry": "../other.py"}))

    def test_invalid_argument_types(self):
        with self.assertRaises(ValueError):
            self.run_source("pass", arguments="--bad")
        with self.assertRaises(ValueError):
            self.run_source("pass", environment={"KEY": 12})

    def test_stop_cpu_loop(self):
        timer = threading.Timer(0.15, stop_event.set)
        timer.start()
        started = time.monotonic()
        try:
            result = self.run_source("import time\nend=time.monotonic()+3\nwhile time.monotonic()<end:\n    value=1+1\n")
        finally:
            timer.cancel()
            timer.join()
        self.assertEqual(result["status"], "stopped")
        self.assertLess(time.monotonic() - started, 2)

    def test_stop_sleep_and_child_thread(self):
        timer = threading.Timer(0.2, stop_event.set)
        timer.start()
        started = time.monotonic()
        try:
            result = self.run_source(
                "import threading, time\ndef task():\n    time.sleep(3)\n"
                "threading.Thread(target=task).start()\ntime.sleep(3)\n")
        finally:
            timer.cancel()
            timer.join()
        self.assertEqual(result["status"], "stopped")
        self.assertLess(time.monotonic() - started, 2)

    def test_project_module_cache_is_cleared(self):
        (self.root / "pocket_test_helper.py").write_text("value=42", encoding="utf-8")
        self.run_source("import pocket_test_helper\nprint(pocket_test_helper.value)")
        self.assertNotIn("pocket_test_helper", sys.modules)
        self.assertNotIn("pypocket", sys.modules)

    def test_standard_library_service_dependencies(self):
        result = self.run_source("import ssl, sqlite3, socket, zipfile, http.server\nprint(sqlite3.sqlite_version)")
        self.assertEqual(result["status"], "finished")


if __name__ == "__main__":
    unittest.main()
