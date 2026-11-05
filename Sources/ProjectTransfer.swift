import Foundation

struct PocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ProjectTransfer {
    static let limit = 50 * 1024 * 1024

    private static func destination(extension suffix: String) throws -> URL {
        guard ["py", "zip"].contains(suffix.lowercased()) else {
            throw PocketError(message: "请选择 .py 或 .zip 文件；远程地址需要指向这两种文件。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pypocket-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("source." + suffix.lowercased())
    }

    static func local(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let output = try destination(extension: source.pathExtension)
            do {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                FileManager.default.createFile(atPath: output.path, contents: nil)
                let writer = try FileHandle(forWritingTo: output)
                defer { try? writer.close() }
                var size = 0
                while let block = try input.read(upToCount: 128 * 1024), !block.isEmpty {
                    size += block.count
                    guard size <= limit else { throw PocketError(message: "文件超过 50 MB 上限。") }
                    try writer.write(contentsOf: block)
                }
                return output
            } catch {
                cleanup(output)
                throw error
            }
        }.value
    }

    static func remote(_ url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw PocketError(message: "远程导入仅支持不含账号密码的 HTTPS 文件链接。")
        }
        let output = try destination(extension: url.pathExtension)
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 180
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.url?.scheme?.lowercased() == "https" else {
                throw PocketError(message: "下载失败，请使用原始文件链接而不是网页地址。")
            }
            guard response.expectedContentLength <= Int64(limit) else {
                throw PocketError(message: "远程文件超过 50 MB 上限。")
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            var buffer = Data()
            var size = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                size += 1
                guard size <= limit else { throw PocketError(message: "下载内容超过 50 MB 上限。") }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try writer.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try writer.write(contentsOf: buffer) }
            return output
        } catch {
            cleanup(output)
            throw error
        }
    }

    static func cleanup(_ staged: URL) {
        let directory = staged.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("pypocket-import-"),
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
