import Foundation
import Darwin

private var h3StopSignal: Int32 = 0

final class OwnedProcessScope {
    let root: ProcessIdentity
    private(set) var identities: [Int32: ProcessIdentity]
    init(process: Process) throws {
        guard let root = ProcessIdentity.capture(process.processIdentifier), root.parentPID == getpid() else { throw StudioError.invalid("无法确认单镜子进程所有权。") }
        self.root = root; identities = [root.pid: root]
    }
    func refresh() {
        var pending = [root], visited = Set<Int32>()
        while let parent = pending.popLast(), visited.count < 64 {
            guard visited.insert(parent.pid).inserted, parent.stillSameProcess else { continue }
            var pids = [Int32](repeating: 0, count: 64)
            let bytes = pids.withUnsafeMutableBytes { proc_listchildpids(parent.pid, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { continue }
            for pid in pids.prefix(min(64, Int(bytes) / MemoryLayout<Int32>.size)) where pid > 0 {
                guard let child = ProcessIdentity.capture(pid), child.parentPID == parent.pid else { continue }
                identities[pid] = child; pending.append(child)
            }
        }
    }
    var living: [ProcessIdentity] { identities.values.filter(\.stillSameProcess) }
    func stop(_ signal: Int32) {
        refresh()
        for identity in living where identity.pid != root.pid { identity.signal(signal) }
        root.signal(signal)
    }
}

final class H3LineAssembler {
    private var pending = Data()
    func append(_ data: Data) -> [String] {
        pending.append(data); var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            if index > pending.startIndex { lines.append(String(decoding: pending[..<index], as: UTF8.self)) }
            pending.removeSubrange(...index)
        }
        if pending.count > 262144 { lines.append("[oversized native line] " + String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        return lines
    }
    func finish() -> [String] { defer { pending.removeAll() }; return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)] }
}

final class H3ChildProcess {
    let process = Process()
    private let readers = DispatchGroup()
    private var pipes: [Pipe] = []
    func start(executable: URL, arguments: [String], directory: URL, onLine: @escaping (String, Bool) -> Void) throws {
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe(); pipes = [stdout, stderr]
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        for (index, pipe) in pipes.enumerated() {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [readers] in
                defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                let assembler = H3LineAssembler()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    for line in assembler.append(data) { onLine(line, index == 1) }
                }
                for line in assembler.finish() { onLine(line, index == 1) }
            }
        }
    }
    func drain() { _ = readers.wait(timeout: .now() + 3) }
}

struct H3NativeStatus: Decodable {
    var status: String; var job_id: String; var output_dir: String; var clip_path: String
    var controller_pid: Int32?; var vpipe_pid: Int32?; var native_exit_code: Int32?
    var latest_progress: String?; var selected_for_production: Bool
}
struct H3TechnicalReport: Decodable {
    var status: String; var job_id: String; var clip_path: String; var clip_sha256: String
    var native_exit_code: Int32; var decoded_video_frames: Int; var dimensions: [Int]; var fps: Int
    var strict_full_av_decode: String; var strict_lossless_decode: String; var native_lossless_frames: Int
    var original_frozen_files_unchanged: Bool; var selected_for_production: Bool; var visual_review: String
    var simulated: Bool?
}

enum H3Progress {
    static func event(_ line: String) -> EngineEvent? {
        if let progress = VpipePhaseProgressParser.parse(line) { return progress }
        guard line.contains("[PROGRESS]") || line.contains("[STAGE]") else { return nil }
        let expression = #"\[PROGRESS\]\s+'([^']+)' ended"#
        if let regex = try? NSRegularExpression(pattern: expression), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) {
            return EngineEvent(type: "stage", stage: String(line[range]) + " 阶段结束 · 等待下一阶段")
        }
        return EngineEvent(type: "stage", stage: line.contains("[STAGE]") ? String(line.replacingOccurrences(of: "[STAGE]", with: "").trimmingCharacters(in: .whitespaces).prefix(180)) : "原生阶段进度待确认")
    }
}

enum H3Supervisor {
    private static let outputLock = NSLock()
    static func emit(_ event: EngineEvent) {
        outputLock.lock(); defer { outputLock.unlock() }
        if let data = try? JSONEncoder().encode(event) {
            do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
            catch { h3StopSignal = 1 }
        }
    }
    static func ownerPresent(_ request: H3WorkerRequest) -> Bool {
        guard request.owner.stillSameProcess,
              let data = try? H3Files.read(URL(fileURLWithPath: request.workspace + "/owner.json"), limit: 1024),
              let session = try? JSONDecoder().decode(UUID.self, from: data) else { return false }
        return session == request.sessionID
    }
    static func stopOwned(_ child: H3ChildProcess, scope: OwnedProcessScope, mock: Bool) {
        scope.stop(SIGTERM)
        let deadline = Date().addingTimeInterval(mock ? 1.2 : 35)
        while child.process.isRunning && Date() < deadline { scope.refresh(); Thread.sleep(forTimeInterval: 0.1) }
        // Captured birth times remain valid even if a child is reparented. Never
        // send a signal to a PID whose captured process identity no longer matches.
        if child.process.isRunning || scope.living.contains(where: { $0.pid != scope.root.pid }) { scope.stop(SIGKILL) }
        child.process.waitUntilExit(); child.drain()
    }
    static func run(requestURL: URL) -> Int32 {
        if let request = try? JSONDecoder().decode(H3WorkerRequest.self,from:H3Files.read(requestURL)),request.binding.appTaskID != nil { return H3ABSupervisor.run(requestURL:requestURL) }
        signal(SIGTERM) { _ in h3StopSignal = 1 }; signal(SIGINT) { _ in h3StopSignal = 1 }
        // The parent can crash and close stdout before owner detection. A broken
        // pipe must trigger cleanup, never terminate the supervisor first.
        signal(SIGPIPE, SIG_IGN)
        var child: H3ChildProcess?; var scope: OwnedProcessScope?; var request: H3WorkerRequest?
        var logHandle: FileHandle?; let assembler = H3LineAssembler(); var seen = Set<String>(); var statusPhase: String?
        do {
            let loaded = try JSONDecoder().decode(H3WorkerRequest.self, from: H3Files.read(requestURL)); request = loaded
            _ = try H3Files.inside(loaded.attemptDirectory, loaded.workspace + "/candidates")
            guard loaded.version == 1, ownerPresent(loaded) else { throw StudioError.invalid("应用已结束或任务所有者变化，未投递单镜。") }
            let receiptURL = URL(fileURLWithPath: loaded.workspace + "/h3-dispatch/" + loaded.binding.jobSHA256 + ".json")
            let receipt = try JSONDecoder().decode(H3DispatchReceipt.self, from: H3Files.read(receiptURL))
            guard receipt.jobSHA256 == loaded.binding.jobSHA256, receipt.appJobID == loaded.appJobID, receipt.sessionID == loaded.sessionID else { throw StudioError.invalid("单镜投递记录不匹配。") }
            let job = try loaded.binding.revalidate()
            try loaded.binding.requireExecutionAuthorization()
            let mock = loaded.binding.runtime.mode == .mock
            let executable = URL(fileURLWithPath: loaded.binding.runtime.executable)
            let arguments = mock ? ["--h3-mock-wrapper", requestURL.path] : [loaded.binding.runnerPath, "--job", loaded.binding.jobPath, "--work-dir", loaded.binding.runtime.workDirectory, "--run"]
            emit(EngineEvent(type: "stage", stage: mock ? "模拟单镜启动 · CPU" : "单镜启动 · 原生引擎预检", message: "单次投递；后续队列保持暂停。"))
            guard h3StopSignal == 0, ownerPresent(loaded) else { return 130 }
            let generator = H3ChildProcess(); child = generator
            try generator.start(executable: executable, arguments: arguments, directory: URL(fileURLWithPath: loaded.binding.runtime.workDirectory)) { line, stderr in
                emit(EngineEvent(type: "log", message: (stderr ? "controller stderr: " : "controller stdout: ") + line))
            }
            let ownership = try OwnedProcessScope(process: generator.process); scope = ownership
            var nextPoll = Date.distantPast, nextOwnedEvent = Date.distantPast
            func progress(_ line: String) {
                guard seen.insert(line).inserted else { return }
                if seen.count > 2048 { seen = [line] }
                if let event = H3Progress.event(line) { emit(event) }
            }
            func poll() throws {
                if FileManager.default.fileExists(atPath: loaded.binding.nativeStatus.path) {
                    let status = try JSONDecoder().decode(H3NativeStatus.self, from: H3Files.read(loaded.binding.nativeStatus))
                    guard status.job_id == job.job_id, status.output_dir == job.output_dir, status.clip_path == job.clip_path,
                          status.controller_pid == generator.process.processIdentifier, !status.selected_for_production else { throw StudioError.invalid("原生状态不属于当前自有单镜。") }
                    if statusPhase != status.status {
                        statusPhase = status.status
                        let label: String
                        switch status.status {
                        case "starting": label = "原生引擎启动"
                        case "generating": label = "原生模型运行 · 等待阶段进度"
                        case "stopping": label = "正在停止自有单镜"
                        case "native_completed_pending_validation": label = "原生完成 · 等待严格验证"
                        case "failed_no_auto_retry": label = "原生执行失败 · 不自动重试"
                        default: label = "原生状态：" + status.status
                        }
                        emit(EngineEvent(type: "stage", stage: label))
                    }
                    if let line = status.latest_progress { progress(line) }
                }
                if logHandle == nil && FileManager.default.fileExists(atPath: loaded.binding.nativeLog.path) {
                    _ = try H3Files.inside(loaded.binding.nativeLog.path, job.output_dir)
                    logHandle = try FileHandle(forReadingFrom: loaded.binding.nativeLog)
                }
                if let logHandle {
                    while let data = try logHandle.read(upToCount: 65536), !data.isEmpty {
                        for line in assembler.append(data) {
                            emit(EngineEvent(type: "log", message: "native: " + line)); progress(line)
                        }
                    }
                }
                ownership.refresh()
                if Date() >= nextOwnedEvent {
                    emit(EngineEvent(type: "owned", ownedProcesses: ownership.living))
                    nextOwnedEvent = Date().addingTimeInterval(10)
                }
            }
            var nextOwnerCheck = Date.distantPast, ownerMissing = false
            func cancelled() -> Bool {
                if Date() >= nextOwnerCheck { ownerMissing = !ownerPresent(loaded); nextOwnerCheck = Date().addingTimeInterval(1) }
                return h3StopSignal != 0 || ownerMissing
            }
            while generator.process.isRunning {
                if cancelled() {
                    emit(EngineEvent(type: "stage", stage: "正在停止自有单镜 · 保留输出"))
                    stopOwned(generator, scope: ownership, mock: mock); try? logHandle?.close()
                    if FileManager.default.fileExists(atPath: job.clip_path) { emit(EngineEvent(type: "partial_output", path: job.clip_path)) }
                    return 130
                }
                if Date() >= nextPoll { try poll(); nextPoll = Date().addingTimeInterval(mock ? 0.1 : 2) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            generator.process.waitUntilExit(); generator.drain(); try poll()
            for line in assembler.finish() { emit(EngineEvent(type: "log", message: "native: " + line)); progress(line) }
            try? logHandle?.close(); logHandle = nil
            guard h3StopSignal == 0, ownerPresent(loaded) else { return 130 }
            guard generator.process.terminationStatus == 0 else { throw StudioError.invalid("原生 wrapper 退出代码 \(generator.process.terminationStatus)，不会自动重试。") }
            let final = try JSONDecoder().decode(H3NativeStatus.self, from: H3Files.read(loaded.binding.nativeStatus))
            guard final.status == "native_completed_pending_validation", final.native_exit_code == 0, FileManager.default.fileExists(atPath: job.clip_path) else { throw StudioError.invalid("原生 exit 0 尚未确认完整候选，未标为成功。") }
            // Keep a preview/reference even when validation is cancelled or fails.
            // This event never satisfies the successful-completion condition.
            emit(EngineEvent(type: "partial_output", path: job.clip_path))
            emit(EngineEvent(type: "stage", stage: "严格验证候选 · 画面审查仍待进行"))
            let validation = H3ChildProcess(); child = validation
            let validationArgs = mock ? ["--h3-mock-validator", requestURL.path] : [loaded.binding.validatorPath, "--job", loaded.binding.jobPath]
            try validation.start(executable: executable, arguments: validationArgs, directory: URL(fileURLWithPath: loaded.binding.runtime.workDirectory)) { line, stderr in
                emit(EngineEvent(type: "log", message: (stderr ? "validator stderr: " : "validator stdout: ") + line))
            }
            let validationScope = try OwnedProcessScope(process: validation.process); scope = validationScope
            var nextValidationOwnedEvent = Date.distantPast
            while validation.process.isRunning {
                validationScope.refresh()
                if Date() >= nextValidationOwnedEvent {
                    emit(EngineEvent(type: "owned", ownedProcesses: validationScope.living)); nextValidationOwnedEvent = Date().addingTimeInterval(10)
                }
                if cancelled() { stopOwned(validation, scope: validationScope, mock: mock); return 130 }
                Thread.sleep(forTimeInterval: 0.1)
            }
            validation.process.waitUntilExit(); validation.drain()
            guard h3StopSignal == 0, ownerPresent(loaded) else { return 130 }
            guard validation.process.terminationStatus == 0 else { throw StudioError.invalid("严格技术验证失败（退出 \(validation.process.terminationStatus)），候选保留，队列暂停。") }
            let reportURL = try H3Files.inside(job.output_dir + "/technical-validation.json", job.output_dir)
            let report = try JSONDecoder().decode(H3TechnicalReport.self, from: H3Files.read(reportURL))
            let expectedFrames = mock ? 48 : job.profile.frames, expectedDimensions = mock ? [384, 224] : [job.profile.width, job.profile.height]
            guard report.status == "technical_pass_visual_review_pending", report.job_id == job.job_id, report.clip_path == job.clip_path,
                  report.native_exit_code == 0, report.decoded_video_frames == expectedFrames, report.native_lossless_frames == expectedFrames,
                  report.dimensions == expectedDimensions, report.fps == 24, report.strict_full_av_decode == "pass", report.strict_lossless_decode == "pass",
                  report.original_frozen_files_unchanged, !report.selected_for_production, report.visual_review == "pending", (report.simulated ?? false) == mock,
                  try WorkspaceDigest.sha256(try H3Files.inside(report.clip_path, job.output_dir)) == report.clip_sha256 else { throw StudioError.invalid("严格验证报告或候选指纹不匹配；未接受输出。") }
            emit(EngineEvent(type: "technical_pass", stage: mock ? "CPU 模拟协议通过 · 非真实 H3" : "自动技术检查通过 · 候选已保存", path: job.clip_path, reportPath: reportURL.path, simulated: mock))
            return 0
        } catch {
            if let child, let scope, child.process.isRunning { stopOwned(child, scope: scope, mock: request?.binding.runtime.mode == .mock) }
            else if let child, child.process.isRunning {
                // Foundation still owns this exact child even if metadata was
                // unavailable. Do not invent identities for any descendants.
                child.process.terminate(); child.process.waitUntilExit(); child.drain()
            }
            try? logHandle?.close()
            if let request, FileManager.default.fileExists(atPath: request.binding.clipPath) { emit(EngineEvent(type: "partial_output", path: request.binding.clipPath)) }
            emit(EngineEvent(type: "error", message: error.localizedDescription)); return h3StopSignal != 0 ? 130 : 1
        }
    }
}
