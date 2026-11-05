# PyPocket

在 iPhone 上运行的 Python 工作台：导入 `.py` / ZIP 项目或从 HTTPS 链接下载，内置 CPython 3.15 直接执行，可选「静音音频」尽力保活，让脚本和本地 HTTP 服务在切后台后继续运行。所有项目保存在本机，不注册任何账号。

## 功能

- 工作台：单项目运行 / 停止（协作式，可中断 Python 循环与 `time.sleep`）、运行计时
- 项目库：文件导入（`.py` / `.zip`，50 MB 上限）、HTTPS 链接下载、入口与参数 / 环境变量配置、内置源码编辑器、两个零依赖示例
- 控制台：实时输出、复制 / 导出 / 清空，文件日志自动轮转（2 MB × 2）
- 本地服务：`http://127.0.0.1:<端口>` 内置 WebView 预览与连通性检查
- 设置：后台运行（静音音频）、前台屏幕常亮、运行边界说明、运行时许可证

## 运行边界（重要）

- **不是沙箱**：脚本与 App 共享进程，仅运行你信任的代码；导入不会自动执行任何代码。
- **不支持** `pip install`、`subprocess` / Shell、监听局域网默认关闭；纯 Python 依赖可随 ZIP 的 `vendor/` 目录导入。
- **后台保活是"尽力"**：静音音频在脚本运行且开启开关时启动；来电、系统调度、划掉 App、设备重启都会中断且不会自动恢复。
- **单任务**：同时运行一个项目；多次运行共享解释器，项目模块缓存会清理但全局状态由脚本自负。
- 上架 App Store 需自行评估下载执行代码（2.5.2）与后台音频（2.5.4）的审核合规。

## 构建（macOS）

```bash
brew install xcodegen
./scripts/build.sh            # 未签名真机 IPA
./scripts/build.sh simulator  # 模拟器构建 + Python 测试
python3 -m unittest discover -s tests   # 纯逻辑测试（Windows 也可跑）
```

运行时来源固定为 [Python-Apple-support 3.15-b3](https://github.com/beeware/Python-Apple-support/releases/tag/3.15-b3)（SHA-256 校验），原生扩展在构建时自动转换为 App Store 合规 Framework 并生成 `.fwork` 索引；CA 根证书取自 Certifi 2026.10.19（含 emSign 事件修复），均附带许可证文本。

## 技术参考（未复制代码）

- [SideInjector](https://github.com/gugegxy-jpg/SideInjector) · UI 与「执行期间不被打断」设置的交互参考
- [AListServer (alist-expo)](https://github.com/gendago/alist-expo) · 后台音频保活思路参考（AVAudioSession `.playback` + `.mixWithOthers` + 循环播放）
- [CPython PEP 730](https://docs.python.org/3/using/ios.html) · iOS 嵌入模式与 Framework 化加载

本仓库自有代码以 MIT 发布；随包分发的 CPython、Certifi 等遵循各自许可证（App 内「设置 → 运行时许可证」可查看全文）。
