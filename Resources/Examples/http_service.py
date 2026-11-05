"""零第三方依赖的本机 HTTP 服务。停止按钮会协作结束请求循环。"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import time

from pypocket import cancelled


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        data = json.dumps({
            "app": "PyPocket",
            "message": "你的 Python 服务正在 iPhone 上运行。",
            "path": self.path,
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        }, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        print(f"[HTTP] {self.address_string()} · {format % args}", flush=True)

    def setup(self):
        self.request.settimeout(2)
        super().setup()


port = int(os.environ.get("PORT", "8000"))
# 默认仅本机可访问。开放局域网前应自行增加认证与请求限制。
with HTTPServer(("127.0.0.1", port), Handler) as server:
    server.timeout = 0.5
    print(f"服务已启动：http://127.0.0.1:{port}/", flush=True)
    print("点击工作台的“打开预览”；若需要切后台，请开启静音音频保活。", flush=True)
    while not cancelled():
        server.handle_request()

print("HTTP 服务已停止。")
