import Combine
import Foundation
import SwiftUI
import UIKit

struct ScriptProject: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var entry: String
    var files: [String]
    var arguments: String
    var environment: String
    var previewPort: Int
    var createdAt: String
}

@MainActor
final class AppModel: ObservableObject {
    enum RunState: String {
        case idle = "就绪", running = "运行中", stopping = "等待停止"
        case finished = "已完成", stopped = "已停止", failed = "运行失败"
        var active: Bool { self == .running || self == .stopping }
    }

    @Published var projects: [ScriptProject] = []
    @Published var selectedID: String?
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var runningID: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var importing = false
    @Published var errorMessage: String?
    @Published var health = "尚未检查"
    @Published var backgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: "backgroundEnabled"); reconcile() }
    }
    @Published var preventSleep: Bool {
        didSet { UserDefaults.standard.set(preventSleep, forKey: "preventSleep"); reconcile() }
    }
    let console = ConsoleStore()
    let audio = BackgroundAudio()
    let projectsURL: URL
    private var scene: ScenePhase = .active
    private let engine = PythonEngine.shared()

    var selected: ScriptProject? { projects.first { $0.id == selectedID } }
    var busy: Bool { runState.active || importing }

    init() {
        backgroundEnabled = UserDefaults.standard.bool(forKey: "backgroundEnabled")
        preventSleep = UserDefaults.standard.bool(forKey: "preventSleep")
        projectsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch { errorMessage = error.localizedDescription }
        let logger = console
        engine.logHandler = { text in logger.append(text) }
        audio.log = { text in logger.append(text) }
        reload()
        if UserDefaults.standard.string(forKey: "activeProject") != nil {
            console.append("[恢复] 上次运行未正常结束，可能被系统终止；不会自动重新执行脚本。\n")
            UserDefaults.standard.removeObject(forKey: "activeProject")
        }
        reconcile()
    }

    func reload() {
        do {
            let directories = try FileManager.default.contentsOfDirectory(at: projectsURL,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var loaded: [ScriptProject] = []
            for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
                do {
                    let file = directory.appendingPathComponent("project.json")
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1024 * 1024 else { continue }
                    let project = try JSONDecoder().decode(ScriptProject.self, from: Data(contentsOf: file))
                    guard project.id == directory.lastPathComponent else { continue }
                    loaded.append(project)
                } catch { console.append("[项目] 无法读取 \(directory.lastPathComponent)：\(error.localizedDescription)\n") }
            }
            projects = loaded.sorted { $0.createdAt > $1.createdAt }
            if !projects.contains(where: { $0.id == selectedID }) { selectedID = projects.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func workspace(_ project: ScriptProject) -> URL {
        projectsURL.appendingPathComponent(project.id, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    func entryURL(_ project: ScriptProject) throws -> URL {
        let root = workspace(project).resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(project.entry).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate.pathExtension.lowercased() == "py" else {
            throw PocketError(message: "入口文件必须位于项目内。")
        }
        return candidate
    }

    func save(_ project: ScriptProject) throws {
        guard !busy, projects.contains(where: { $0.id == project.id }), UUID(uuidString: project.id) != nil else {
            throw PocketError(message: "运行或导入期间不能修改项目。")
        }
        _ = try entryURL(project)
        _ = try parameters(project)
        let url = projectsURL.appendingPathComponent(project.id).appendingPathComponent("project.json")
        try JSONEncoder().encode(project).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        reload()
    }

    private func parameters(_ project: ScriptProject) throws -> ([String], [String: String]) {
        guard let args = try JSONSerialization.jsonObject(with: Data(project.arguments.utf8)) as? [String],
              let environment = try JSONSerialization.jsonObject(with: Data(project.environment.utf8)) as? [String: String],
              (1...65535).contains(project.previewPort) else {
            throw PocketError(message: "参数应为字符串 JSON 数组，环境变量应为字符串 JSON 对象；端口范围为 1–65535。")
        }
        return (args, environment)
    }

    func remove(_ project: ScriptProject) {
        guard !busy, projects.contains(where: { $0.id == project.id }), UUID(uuidString: project.id) != nil else { return }
        do {
            try FileManager.default.removeItem(at: projectsURL.appendingPathComponent(project.id))
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func importLocal(_ url: URL, name: String? = nil) {
        guard !busy else { importFailed("请先停止当前任务再导入。"); return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let staged = try await ProjectTransfer.local(url)
                defer { ProjectTransfer.cleanup(staged) }
                try await finishImport(staged, name: name ?? url.deletingPathExtension().lastPathComponent)
            } catch { importFailed("本地导入失败：\(error.localizedDescription)") }
        }
    }

    func importRemote(_ text: String) {
        guard !busy else { importFailed("请先停止当前任务再导入。"); return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            importFailed("请输入有效文件链接。"); return
        }
        importing = true
        console.append("[导入] 开始下载 \(url.absoluteString)\n")
        Task {
            defer { importing = false }
            do {
                let staged = try await ProjectTransfer.remote(url)
                defer { ProjectTransfer.cleanup(staged) }
                try await finishImport(staged, name: url.deletingPathExtension().lastPathComponent)
            } catch { importFailed("远程导入失败：\(error.localizedDescription)") }
        }
    }

    /// 导入失败要同时写控制台并弹提示：控制台是用户排查导入问题的主入口。
    func importFailed(_ message: String) {
        console.append("[导入失败] \(message)\n")
        errorMessage = message
    }

    private func finishImport(_ staged: URL, name: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["source": staged.path, "projects": projectsURL.path, "name": name])
        let response: String = try await withCheckedThrowingContinuation { continuation in
            engine.importProject(json: String(decoding: data, as: UTF8.self)) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: PocketError(message: "导入没有返回结果。")) }
            }
        }
        let project = try JSONDecoder().decode(ScriptProject.self, from: Data(response.utf8))
        reload()
        selectedID = project.id
        console.append("[导入] \(project.name)，入口 \(project.entry)。尚未执行。\n")
    }

    func addExample(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "py", subdirectory: "Examples") else {
            errorMessage = "安装包缺少示例脚本。"; return
        }
        importLocal(url, name: name == "hello" ? "你好，Python" : "本地 HTTP 服务")
    }

    func runSelected() {
        guard !busy, let project = selected else { return }
        do {
            let (args, environment) = try parameters(project)
            _ = try entryURL(project)
            let spec: [String: Any] = ["workspace": workspace(project).path, "entry": project.entry,
                                       "arguments": args, "environment": environment]
            let data = try JSONSerialization.data(withJSONObject: spec)
            runningID = project.id
            runState = .running
            startedAt = Date()
            health = "尚未检查"
            UserDefaults.standard.set(project.id, forKey: "activeProject")
            reconcile()
            engine.run(json: String(decoding: data, as: UTF8.self)) { [weak self] response, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.runState = .failed
                        self.console.append("[错误] \(error.localizedDescription)\n")
                        self.errorMessage = error.localizedDescription
                    } else if let response,
                              let result = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] {
                        switch result["status"] as? String {
                        case "finished": self.runState = .finished
                        case "stopped": self.runState = .stopped
                        default: self.runState = .failed
                        }
                    } else { self.runState = .failed }
                    self.runningID = nil
                    self.health = "任务已结束"
                    UserDefaults.standard.removeObject(forKey: "activeProject")
                    self.reconcile()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        guard runState == .running else { return }
        runState = .stopping
        engine.requestStop()
        console.append("[停止] 已请求停止，正在等待脚本和项目线程退出；原生阻塞调用不能强制终止。\n")
    }

    func sceneChanged(_ value: ScenePhase) {
        scene = value
        reconcile()
        if value == .active, runState.active { checkService() }
    }

    private func reconcile() {
        UIApplication.shared.isIdleTimerDisabled = preventSleep && runState.active && scene == .active
        // inactive 阶段提前启动音频，避免等到系统挂起后才尝试激活会话。
        audio.update(enabled: backgroundEnabled, taskActive: runState.active, foreground: scene == .active)
    }

    var previewURL: URL? {
        guard let project = selected, (1...65535).contains(project.previewPort) else { return nil }
        return URL(string: "http://127.0.0.1:\(project.previewPort)/")
    }

    func checkService() {
        guard let url = previewURL else { return }
        let checkingID = selectedID
        health = "检查中…"
        Task {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            request.httpMethod = "HEAD"
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard checkingID == selectedID else { return }
                if let http = response as? HTTPURLResponse {
                    health = "可连接 · HTTP \(http.statusCode)"
                } else { health = "未收到 HTTP 响应" }
            } catch {
                guard checkingID == selectedID else { return }
                health = "服务不可达（普通脚本不监听端口）"
            }
        }
    }
}
