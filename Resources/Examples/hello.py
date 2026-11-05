"""示例：观察日志，以及前后台切换时脚本是否继续执行。"""
import platform
import sys
import time

print("你好，PyPocket！")
print("Python:", sys.version.split()[0])
print("平台:", platform.system())
print("启动参数:", sys.argv[1:])

for index in range(10):
    print(f"第 {index + 1}/10 次心跳 · {time.strftime('%H:%M:%S')}", flush=True)
    time.sleep(1)

print("脚本执行完成，后台保活会自动释放。")
