"""单任务嵌入式执行器。目录分离不是安全沙箱，只运行用户信任的代码。"""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import runpy
import sys
import threading
import time
import traceback
import types

import _pypocket_native as native


class ScriptStopped(BaseException):
    """协作式停止；不异步打断原生扩展。"""


class Console(io.TextIOBase):
    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def write(self, text):
        if not isinstance(text, str):
            raise TypeError("控制台仅接受文本")
        # 限制单次跨语言传输大小，完整内容由原生日志缓冲处理。
        for offset in range(0, len(text), 8192):
            native.write(text[offset:offset + 8192])
        return len(text)

    def flush(self):
        pass


def execute_json(request: str) -> str:
    spec = json.loads(request)
    root = Path(spec["workspace"]).resolve(strict=True)
    entry = (root / spec["entry"]).resolve(strict=True)
    if not entry.is_relative_to(root) or entry.suffix.lower() != ".py":
        raise ValueError("入口必须是项目内的 .py 文件")
    arguments = spec.get("arguments", [])
    environment = spec.get("environment", {})
    if not isinstance(arguments, list) or not all(isinstance(value, str) for value in arguments):
        raise ValueError("启动参数必须是字符串 JSON 数组")
    if not isinstance(environment, dict) or not all(
        isinstance(key, str) and isinstance(value, str) and key and "=" not in key
        and "\x00" not in key and "\x00" not in value
        for key, value in environment.items()
    ):
        raise ValueError("环境变量必须是字符串键值 JSON 对象")

    saved = (os.getcwd(), sys.argv, list(sys.path), sys.stdin, sys.stdout, sys.stderr)
    old_environment = dict(os.environ)
    old_modules = set(sys.modules)
    old_threads = set(threading.enumerate())
    old_trace = sys.gettrace()
    old_thread_trace = threading.gettrace()
    old_excepthook = threading.excepthook
    original_sleep = time.sleep
    result = {"status": "finished", "exitCode": 0}
    prefix = str(root) + os.sep
    api = types.ModuleType("pypocket")
    api.cancelled = native.cancelled
    api.ScriptStopped = ScriptStopped
    previous_api = sys.modules.get("pypocket")
    sys.modules["pypocket"] = api

    def trace(frame, event, arg):
        # 全局检查取消标记：服务型脚本（如 http.server.serve_forever）主循环在标准库内，
        # 只按项目路径过滤会让主线程永远等不到停止信号。ScriptStopped 是 BaseException，
        # 不会被脚本的 except Exception 吞掉。
        if native.cancelled():
            raise ScriptStopped()
        return trace

    def sleep(seconds):
        if seconds < 0:
            return original_sleep(seconds)
        deadline = time.monotonic() + seconds
        while True:
            if native.cancelled():
                raise ScriptStopped()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            original_sleep(min(0.1, remaining))

    def thread_exception(args):
        if args.exc_type is not ScriptStopped:
            old_excepthook(args)

    try:
        os.chdir(entry.parent)
        sys.argv = [str(entry), *arguments]
        sys.path[:0] = [str(entry.parent), str(root), str(root / "vendor")]
        sys.stdin = io.StringIO("")
        sys.stdout = sys.stderr = Console()
        os.environ.update(environment)
        time.sleep = sleep
        threading.excepthook = thread_exception
        threading.settrace(trace)
        sys.settrace(trace)
        print(f"[运行] {spec['entry']}\n[Python] {sys.version.split()[0]}")
        runpy.run_path(str(entry), run_name="__main__")
    except ScriptStopped:
        result = {"status": "stopped", "exitCode": 130}
        native.write("\n[停止] 脚本已响应停止请求。\n")
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else (0 if error.code is None else 1)
        result = {"status": "finished" if code == 0 else "failed", "exitCode": code}
        if error.code is not None and not isinstance(error.code, int):
            native.write(str(error.code) + "\n")
    except BaseException:
        result = {"status": "failed", "exitCode": 1}
        native.write(traceback.format_exc())
    finally:
        sys.settrace(None)
        try:
            announced = False
            deadline = time.monotonic() + 5.0
            while True:
                remaining = [thread for thread in threading.enumerate()
                             if thread not in old_threads and thread.is_alive()]
                if not remaining:
                    break
                if not announced:
                    native.write("[等待] 项目线程正在退出…\n")
                    announced = True
                for thread in remaining:
                    thread.join(timeout=0.1)
                if time.monotonic() >= deadline:
                    native.write(f"[停止] 仍有 {len(remaining)} 个线程未退出（卡在原生调用或长连接），已不再等待；\n端口监听与定时器可能残留，完全释放请重新打开 App。\n")
                    break
        finally:
            threading.settrace(old_thread_trace)
            threading.excepthook = old_excepthook
            time.sleep = original_sleep
            os.environ.clear()
            os.environ.update(old_environment)
            os.chdir(saved[0])
            sys.argv = saved[1]
            sys.path[:] = saved[2]
            sys.stdin, sys.stdout, sys.stderr = saved[3:]
            for name in set(sys.modules) - old_modules:
                module = sys.modules.get(name)
                location = getattr(module, "__file__", None)
                if location and str(location).startswith(prefix):
                    sys.modules.pop(name, None)
            if previous_api is None:
                sys.modules.pop("pypocket", None)
            else:
                sys.modules["pypocket"] = previous_api
            sys.settrace(old_trace)
    if native.cancelled() and result["status"] == "finished":
        result = {"status": "stopped", "exitCode": 130}
    native.write(f"[结束] {result['status']}，退出码 {result['exitCode']}\n")
    return json.dumps(result)
