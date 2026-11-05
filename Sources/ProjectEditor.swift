import SwiftUI

struct ProjectEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptProject
    @State private var source = ""
    @State private var originalSource = ""
    @State private var sourceLoaded = false
    @State private var error: String?

    init(project: ScriptProject) { _draft = State(initialValue: project) }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目配置") {
                    TextField("项目名称", text: $draft.name)
                    Picker("启动入口", selection: $draft.entry) {
                        ForEach(draft.files, id: \.self) { Text($0).tag($0) }
                    }.disabled(source != originalSource)
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
                Section("入口源码") {
                    if sourceLoaded {
                        TextEditor(text: $source)
                            .font(.system(size: 13, design: .monospaced)).frame(minHeight: 320)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        Text("无法编辑此文件；仅支持不超过 512 KB 的 UTF-8 源码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("配置与编辑").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(model.busy) }
            }
            .task { loadSource() }
            .onChange(of: draft.entry) { _, _ in loadSource() }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func loadSource() {
        sourceLoaded = false
        source = ""
        originalSource = ""
        do {
            let url = try model.entryURL(draft)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512 * 1024 else { return }
            source = try String(contentsOf: url, encoding: .utf8)
            originalSource = source
            sourceLoaded = true
        } catch { sourceLoaded = false }
    }

    private func save() {
        do {
            guard !model.busy else { throw PocketError(message: "运行期间不能修改源码。") }
            try model.save(draft)
            if sourceLoaded && source != originalSource {
                let url = try model.entryURL(draft)
                try Data(source.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
