import Foundation

enum StartupPhase: String, Codable, Sendable {
    case workspaceResolved, stateLoaded, menuCreated, mainWindowCreated, orbCreated, uiPresented
    case statusReadStarted, statusReadTimedOut, statusReadCompleted, statusReadUnavailable, statusPollingStopped, shutdownRequested
}

final class StartupPhaseLog: @unchecked Sendable {
    private struct Entry: Encodable, Sendable { var date: Date; var version: String; var phase: StartupPhase }
    private let file: URL
    private let queue = DispatchQueue(label: "com.wengong.WanshenjiH3Studio.startup-log", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    init(root: URL) { file = root.appendingPathComponent("startup-phases.jsonl") }
    func record(_ phase: StartupPhase) {
        lock.lock()
        guard pending < 16 else { lock.unlock(); return }
        pending += 1; lock.unlock()
        let entry = Entry(date: Date(), version: AppIdentity.version, phase: phase)
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry) else { return }
            // Bounded best-effort diagnostics: no paths, prompts, job IDs, error
            // descriptions or contents. Main actor and shutdown never await this.
            do {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 65_536 {
                    try Data().write(to: file, options: .atomic)
                }
                if !FileManager.default.fileExists(atPath: file.path) { _ = FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
            } catch { /* Optional diagnostics cannot prevent startup or shutdown. */ }
        }
    }
}
