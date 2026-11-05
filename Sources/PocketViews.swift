import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct PocketRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0
    @State private var showImport = false
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { WorkspaceView(showImport: $showImport) }
                .tabItem { Label("工作台", systemImage: "terminal") }.tag(0)
            NavigationStack { ProjectLibrary(showImport: $showImport, tab: $tab) }
                .tabItem { Label("项目", systemImage: "square.stack.3d.up") }.tag(1)
            NavigationStack { ConsoleView(console: model.console) }
                .tabItem { Label("控制台", systemImage: "text.alignleft") }.tag(2)
            NavigationStack { PreferencesView(audio: model.audio) }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .tint(.teal)
        .sheet(isPresented: $showImport) { ImportView() }
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showImport: Bool
    @State private var confirmRun = false
    @State private var showPreview = false
    @State private var editing: ScriptProject?

    var body: some View {
        ZStack {
            PocketBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("ON-DEVICE PYTHON", systemImage: "cpu")
                            .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.teal)
                        Text("把 Python\n装进口袋。")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("脚本、灵感与小服务，就在你的 iPhone 上运行。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                    GlassPanel {
                        HStack {
                            Label("当前任务", systemImage: "command").font(.headline)
                            Spacer()
                            StatusPill(title: model.runState.rawValue, active: model.runState.active)
                        }
                        if let project = model.selected {
                            Menu {
                                ForEach(model.projects) { item in
                                    Button(item.name) { model.selectedID = item.id }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(project.name).font(.title2.bold()).foregroundStyle(.primary)
                                        Text(project.entry).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                            }.disabled(model.busy)
                            HStack(spacing: 12) {
                                StatusPill(title: "CPython 3.15")
                                if model.runState.active, let start = model.startedAt {
                                    Text(start, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                } else { StatusPill(title: "本机执行") }
                            }
                            RunButton(active: model.runState.active,
                                      disabled: model.importing || model.runState == .stopping) {
                                if model.runState.active { model.stop() } else { confirmRun = true }
                            }
                            Button { editing = project } label: {
                                Label("入口、参数与源码", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity)
                            }.disabled(model.busy).font(.subheadline)
                        } else {
                            Text("还没有项目").font(.title2.bold())
                            Text("导入一个 .py 或 ZIP 项目，也可以从示例开始。")
                                .foregroundStyle(.secondary).font(.subheadline)
                            Button { showImport = true } label: {
                                Label("添加第一个项目", systemImage: "plus").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        if model.importing {
                            HStack { ProgressView(); Text("正在导入并检查项目…").font(.caption) }
                        }
                        if model.runState == .stopping {
                            Text("正在等待协作退出。若脚本阻塞在原生调用中，可能需要手动关闭并重新打开 App。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    GlassPanel {
                        HStack {
                            Label("本地服务", systemImage: "network").font(.headline)
                            Spacer()
                            if let url = model.previewURL {
                                Text(":\(url.port ?? 8000)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Text(model.health).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("检查连接", systemImage: "arrow.clockwise") { model.checkService() }
                            Spacer()
                            Button("打开预览", systemImage: "safari") { showPreview = true }
                        }.font(.subheadline).disabled(model.selected == nil)
                    }
                    HStack(spacing: 12) {
                        example("hello", title: "你好，Python", subtitle: "运行第一个脚本", icon: "sparkles")
                        example("http_service", title: "HTTP 服务", subtitle: "启动本机 API", icon: "server.rack")
                    }.disabled(model.busy)
                    Text("仅运行你信任的代码。项目不是独立安全沙箱；原生扩展与系统命令需要额外适配。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 740).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("PyPocket").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("导入", systemImage: "plus") { showImport = true }.disabled(model.busy) }
        .confirmationDialog("运行这个项目？", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("我信任此代码，开始运行") { model.runSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("脚本可访问 App 内的项目文件和网络。导入不会自动安装依赖或执行代码。")
        }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .sheet(isPresented: $showPreview) {
            if let url = model.previewURL { ServicePreview(url: url) }
        }
    }

    private func example(_ name: String, title: String, subtitle: String, icon: String) -> some View {
        Button { model.addExample(name) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(.teal)
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18).pocketGlass(radius: 22)
        }.buttonStyle(.plain)
    }
}

private struct ProjectLibrary: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showImport: Bool
    @Binding var tab: Int
    @State private var deleting: ScriptProject?
    @State private var editing: ScriptProject?
    var body: some View {
        ZStack {
            PocketBackdrop()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if model.projects.isEmpty {
                        ContentUnavailableView("你的脚本收藏夹", systemImage: "folder.badge.plus",
                                               description: Text("从文件或 HTTPS 链接导入，所有项目保存在本机。"))
                    }
                    ForEach(model.projects) { project in
                        GlassPanel {
                            HStack(alignment: .top) {
                                Image(systemName: "doc.text").font(.title2).foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.name).font(.headline)
                                    Text(project.entry).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text("\(project.files.count) 个 Python 文件").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("配置与编辑", systemImage: "pencil") { editing = project }
                                    Button("删除项目", systemImage: "trash", role: .destructive) { deleting = project }
                                } label: { Image(systemName: "ellipsis.circle").padding(4) }.disabled(model.busy)
                            }
                            Button("选择项目", systemImage: "arrow.up.right") {
                                model.selectedID = project.id
                                tab = 0
                            }.disabled(model.busy)
                        }
                    }
                }.padding(20).frame(maxWidth: 740).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("项目库")
        .toolbar { Button("添加", systemImage: "plus") { showImport = true }.disabled(model.busy) }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .confirmationDialog("删除项目及其全部文件？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let deleting { model.remove(deleting) }; deleting = nil }
        }
    }
}

private struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var link = ""
    var body: some View {
        NavigationStack {
            ZStack {
                PocketBackdrop()
                ScrollView {
                    VStack(spacing: 20) {
                        GlassPanel {
                            Label("从文件导入", systemImage: "folder").font(.title3.bold())
                            Text("支持 .py 或 ZIP，最多 50 MB。ZIP 内的纯 Python 依赖可随项目一并导入。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("选择文件", systemImage: "doc.badge.plus") { showFiles = true }
                                .buttonStyle(.borderedProminent).disabled(model.importing)
                        }
                        GlassPanel {
                            Label("从链接下载", systemImage: "link").font(.title3.bold())
                            TextField("https://example.com/main.py", text: $link)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .padding(12).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            Text("请使用 .py / .zip 的原始 HTTPS 文件地址。下载完成后不会自动运行。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("下载并导入", systemImage: "arrow.down.circle") {
                                model.importRemote(link)
                            }.buttonStyle(.borderedProminent).disabled(link.isEmpty || model.importing)
                        }
                        if let message = model.errorMessage {
                            Text(message)
                                .font(.footnote).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(20)
                }
            }
            .navigationTitle("添加项目").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [UTType(filenameExtension: "py") ?? .plainText, .zip]) { result in
                switch result {
                case .success(let url): model.importLocal(url)
                case .failure(let error): model.importFailed("无法读取所选文件：\(error.localizedDescription)")
                }
            }
            .onChange(of: model.selectedID) { _, _ in dismiss() }
        }.presentationDetents([.large])
    }
}

struct ConsoleView: View {
    @ObservedObject var console: ConsoleStore
    var body: some View {
        ZStack {
            PocketBackdrop()
            ScrollView(.vertical) {
                if console.text.isEmpty {
                    Text("输出会出现在这里。\n导入或运行一个项目开始。")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(console.text.components(separatedBy: "\n").suffix(240).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(20)
                }
            }
        }
        .navigationTitle("控制台")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("复制当前日志", systemImage: "doc.on.doc") { UIPasteboard.general.string = console.text }
                ShareLink(item: console.fileURL) { Label("导出日志", systemImage: "square.and.arrow.up") }
                Button("清空", systemImage: "trash") { console.clear() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("长按任意一行可选中并复制片段 · 显示最近 240 行，长行自动换行")
                .font(.caption2).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.thinMaterial)
        }
    }
}

private struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var audio: BackgroundAudio
    var body: some View {
        ZStack {
            PocketBackdrop()
            ScrollView {
                VStack(spacing: 20) {
                    GlassPanel {
                        Label("执行期间", systemImage: "moon.stars").font(.headline)
                        Toggle("后台运行（静音音频）", isOn: $model.backgroundEnabled)
                        Text(audio.status).font(.caption).foregroundStyle(audio.isPlaying ? .teal : .secondary)
                        Divider()
                        Toggle("前台保持屏幕常亮", isOn: $model.preventSleep)
                        Text("仅在任务运行时生效。静音音频会增加耗电，也可能被来电、系统调度或强制退出中断；不保证永久后台运行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GlassPanel {
                        Label("运行边界", systemImage: "checkmark.shield").font(.headline)
                        Text("• 同时运行一个项目，停止采用协作方式。\n• 支持标准库及兼容的纯 Python 依赖。\n• 不自动执行 pip、Shell 或子进程。\n• 环境变量保存在项目配置内，请勿随意分享。\n• 项目之间不是安全沙箱，仅运行可信代码。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    GlassPanel {
                        Label("关于 PyPocket", systemImage: "terminal").font(.headline)
                        Text("1.0 · iOS 17+ · 内嵌 CPython 3.15").font(.subheadline)
                        if #available(iOS 26.0, *) {
                            StatusPill(title: "原生 Liquid Glass", active: true)
                        } else { StatusPill(title: "系统毛玻璃 Material") }
                        Text("UI 为独立实现。以下项目作为产品与技术参考，未复制其 UI 或保活源码。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("界面参考 · SideInjector", destination: URL(string: "https://github.com/gugegxy-jpg/SideInjector")!)
                        Link("后台参考 · AListServer", destination: URL(string: "https://github.com/gendago/alist-expo")!)
                        Link("运行时 · Python Apple Support", destination: URL(string: "https://github.com/beeware/Python-Apple-support")!)
                        NavigationLink("Python 与依赖许可证") { RuntimeLicensesView() }
                    }
                }.padding(20).frame(maxWidth: 740).frame(maxWidth: .infinity)
            }
        }.navigationTitle("设置")
    }
}

private struct RuntimeLicensesView: View {
    var body: some View {
        ScrollView {
            Text((try? String(contentsOf: Bundle.main.url(forResource: "runtime-licenses", withExtension: "txt")!, encoding: .utf8)) ?? "请检查安装包中的运行时许可文件。")
                .font(.caption.monospaced()).textSelection(.enabled).padding()
        }.navigationTitle("运行时许可证")
    }
}

struct ServicePreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var body: some View {
        NavigationStack {
            LocalWebView(url: url)
                .navigationTitle("本地服务").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .safeAreaInset(edge: .bottom) { Text(url.absoluteString).font(.caption.monospaced()).padding(8) }
        }
    }
}

private struct LocalWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
