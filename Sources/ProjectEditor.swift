import SwiftUI

struct ProjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptProject
    @State private var showSourceEditor = false
    @State private var error: String?

    init(project: ScriptProject) { _draft = State(initialValue: project) }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目配置") {
                    TextField("项目名称", text: $draft.name)
                    Picker("启动入口", selection: $draft.entry) {
                        ForEach(draft.files, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("预览端口", value: $draft.previewPort, format: .number).keyboardType(.numberPad)
                    Text("预览端口只控制 App 打开的地址；脚本需自行监听同一个端口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("启动参数 · JSON 数组") {
                    TextEditor(text: $draft.arguments).font(.system(.body, design: .monospaced)).frame(minHeight: 65)
                    Text("例如 [\"--port\", \"8000\"]；不经过 Shell 解析。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("环境变量 · JSON 对象") {
                    TextEditor(text: $draft.environment).font(.system(.body, design: .monospaced)).frame(minHeight: 65)
                    Text("例如 {\"PORT\": \"8000\"}。保存在本机项目配置内。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        showSourceEditor = true
                    } label: {
                        Label("编辑入口源码（\(draft.entry)）", systemImage: "square.and.pencil")
                    }
                    Text("配置页不加载代码内容，大文件也能秒开。需要改代码时再进入编辑器。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("项目配置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(model.busy) }
            }
            .sheet(isPresented: $showSourceEditor) {
                SourceEditor(project: draft)
            }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func save() {
        do {
            guard !model.busy else { throw PocketError(message: "运行期间不能修改项目。") }
            try model.save(draft)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// 独立源码编辑器：只有用户点进来才读取文件，配置页保持轻量。
private struct SourceEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: ScriptProject
    @State private var source = ""
    @State private var originalSource = ""
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    TextEditor(text: $source)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Text("无法编辑此文件；仅支持不超过 512 KB 的 UTF-8 源码。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("编辑 \(project.entry)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!loaded || source == originalSource || model.busy)
                }
            }
            .task { load() }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func load() {
        do {
            let url = try model.entryURL(project)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512 * 1024 else { return }
            source = try String(contentsOf: url, encoding: .utf8)
            originalSource = source
            loaded = true
        } catch { loaded = false }
    }

    private func save() {
        do {
            guard !model.busy else { throw PocketError(message: "运行期间不能修改源码。") }
            let url = try model.entryURL(project)
            try Data(source.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
