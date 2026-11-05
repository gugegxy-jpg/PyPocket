import Combine
import Foundation

/// 工作线程可直接追加；批量落盘和 UI 刷新，避免高频 print 阻塞主线程。
final class ConsoleStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var text = ""
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.pypocket.logs", qos: .utility)
    private var pending = ""
    private var scheduled = false
    private var tail = ""
    let fileURL: URL

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PyPocket/Logs", isDirectory: true)
        fileURL = root.appendingPathComponent("console.log")
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { text = "无法创建日志目录：\(error.localizedDescription)\n" }
    }

    func append(_ value: String) {
        lock.lock()
        pending.append(value)
        if pending.utf8.count > 256 * 1024 {
            pending = "[日志限流：已截断过量输出]\n" + String(pending.suffix(64000))
        }
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending = ""
        scheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        tail = String((tail + batch).suffix(60000))
        do {
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 2 * 1024 * 1024 {
                let previous = fileURL.deletingLastPathComponent().appendingPathComponent("console.previous.log")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: fileURL, to: previous)
            }
            if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(batch.utf8))
        } catch {
            tail += "\n[日志] 写入失败：\(error.localizedDescription)\n"
        }
        let snapshot = tail
        DispatchQueue.main.async { self.text = snapshot }
    }

    func clear() {
        lock.lock()
        pending = ""
        lock.unlock()
        queue.async {
            self.tail = ""
            do { try Data().write(to: self.fileURL, options: .atomic) }
            catch { self.tail = "清空日志失败：\(error.localizedDescription)" }
            let snapshot = self.tail
            DispatchQueue.main.async { self.text = snapshot }
        }
    }
}
