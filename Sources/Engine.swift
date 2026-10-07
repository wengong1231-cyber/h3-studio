import Foundation
import AppKit
import Darwin

private var fixtureSignal: Int32 = 0

enum FixtureWorker {
    static func emit(_ event: EngineEvent) {
        if let data = try? JSONEncoder().encode(event) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    static func run(requestURL: URL) -> Int32 {
        signal(SIGTERM) { _ in fixtureSignal = 1 }
        signal(SIGINT) { _ in fixtureSignal = 1 }
        do {
            let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: requestURL))
            let directory = URL(fileURLWithPath: request.outputDirectory).standardizedFileURL
            let root = URL(fileURLWithPath: request.workspace).standardizedFileURL
            guard directory.path.hasPrefix(root.appendingPathComponent("candidates").path + "/"),
                  directory.resolvingSymlinksInPath().path == directory.path,
                  (0...1).contains(request.delay) else { throw StudioError.invalid("验证输出目录或参数无效。") }
            func cancelled() -> Bool {
                if fixtureSignal != 0 || kill(request.ownerPID, 0) != 0 { return true }
                let lease = root.appendingPathComponent("owner.json")
                guard let data = try? Data(contentsOf: lease),
                      let owner = try? JSONDecoder().decode(UUID.self, from: data) else { return true }
                return owner != request.sessionID
            }
            emit(EngineEvent(type: "stage", stage: "准备合成验证", message: "CPU 合成生成器；不加载模型，不使用 H3。"))
            Thread.sleep(forTimeInterval: 0.15)
            guard !cancelled() else { return 130 }
            let frames = directory.appendingPathComponent("frames", isDirectory: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: false)
            emit(EngineEvent(type: "stage", stage: "生成验证帧"))
            for frame in 0..<48 {
                if cancelled() { emit(EngineEvent(type: "log", message: "合成任务已取消，保留已写出的候选文件。")); return 130 }
                if request.fail && frame == 12 { throw StudioError.invalid("合成故障注入：第 13 帧写出失败。可重试验证恢复。") }
                let rgb = makeFrame(frame: frame, width: 384, height: 224)
                var ppm = Data("P6\n384 224\n255\n".utf8)
                ppm.append(rgb)
                let path = frames.appendingPathComponent(String(format: "frame-%04d.ppm", frame))
                try ppm.write(to: path, options: .withoutOverwriting)
                if frame == 0 { try savePNG(rgb, to: directory.appendingPathComponent("poster.png")) }
                emit(EngineEvent(type: "progress", stage: "生成验证帧", completed: frame + 1, total: 48, unit: "帧"))
                Thread.sleep(forTimeInterval: request.delay)
            }
            guard !cancelled() else { return 130 }
            emit(EngineEvent(type: "stage", stage: "封装候选视频", message: "48 帧已写出；封装阶段没有可用百分比。"))
            guard FileManager.default.isExecutableFile(atPath: request.ffmpeg) else { throw StudioError.invalid("未找到已核实的 FFmpeg，请由维护任务更新固定路径。") }
            let output = directory.appendingPathComponent("synthetic-candidate.mp4")
            let encoder = Process()
            encoder.executableURL = URL(fileURLWithPath: request.ffmpeg)
            encoder.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-threads", "1", "-framerate", "24", "-i", frames.appendingPathComponent("frame-%04d.ppm").path, "-frames:v", "48", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1", "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path]
            encoder.standardOutput = FileHandle.nullDevice
            encoder.standardError = FileHandle.standardError
            try encoder.run()
            emit(EngineEvent(type: "child", message: "已启动本任务的单线程 CPU 封装进程。", childPID: encoder.processIdentifier))
            while encoder.isRunning {
                if cancelled() {
                    encoder.terminate()
                    let deadline = Date().addingTimeInterval(1)
                    while encoder.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                    if encoder.isRunning { kill(encoder.processIdentifier, SIGKILL) }
                    encoder.waitUntilExit()
                    return 130
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard encoder.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { throw StudioError.invalid("合成候选视频封装失败，详见错误日志。") }
            emit(EngineEvent(type: "stage", stage: "验证候选文件"))
            let metadata: [String: Any] = ["generator": "CPU synthetic fixture", "job_id": request.jobID.uuidString,
                                          "frames": 48, "fps": 24, "selected_for_production": false,
                                          "visual_review": "not-performed", "created_at": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("generation.json"), options: .withoutOverwriting)
            guard !cancelled() else { return 130 }
            emit(EngineEvent(type: "output", stage: "候选已生成", path: output.path, message: "合成验证完成；候选未进入正式成片。"))
            return 0
        } catch {
            emit(EngineEvent(type: "error", message: error.localizedDescription))
            return 1
        }
    }

    static func makeFrame(frame: Int, width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        let time = Double(frame) / 47
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                var r = 15 + Int(v * 18), g = 25 + Int(v * 28), b = 43 + Int(v * 32)
                let ridge = 0.53 + 0.16 * sin(u * 10) + 0.06 * cos(u * 27)
                if v > ridge { r = 29; g = 51; b = 63 }
                if v > 0.76 + 0.045 * sin(u * 16) { r = 17; g = 36; b = 49 }
                let sunX = 0.2 + time * 0.56, sunY = 0.25 - 0.07 * sin(time * .pi)
                if pow((u - sunX) * 1.7, 2) + pow(v - sunY, 2) < 0.0016 { r = 230; g = 194; b = 116 }
                let ribbon = 0.72 + 0.045 * sin(u * 12 - time * 4)
                if abs(v - ribbon) < 0.007 && u < time * 0.8 + 0.12 { r = 169; g = 145; b = 96 }
                let idx = (y * width + x) * 3
                pixels[idx] = UInt8(r); pixels[idx + 1] = UInt8(g); pixels[idx + 2] = UInt8(b)
            }
        }
        return Data(pixels)
    }
    static func savePNG(_ rgb: Data, to url: URL, width: Int = 384, height: Int = 224) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                          samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: width * 3, bitsPerPixel: 24), let pointer = bitmap.bitmapData else {
            throw StudioError.invalid("合成预览图创建失败。")
        }
        rgb.copyBytes(to: pointer, count: rgb.count)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw StudioError.invalid("合成预览图编码失败。") }
        try data.write(to: url, options: .withoutOverwriting)
    }
}

final class ProcessRunner {
    let process = Process()
    private let readers = DispatchGroup()
    private var onLine: ((String, Bool) -> Void)?
    private var onExit: ((Int32) -> Void)?

    func start(executable: URL, request: URL, onLine: @escaping (String, Bool) -> Void, onExit: @escaping (Int32) -> Void) throws {
        try start(executable: executable, arguments: ["--fixture-worker", request.path], directory: nil, onLine: onLine, onExit: onExit)
    }
    func start(executable: URL, arguments: [String], directory: URL?, onLine: @escaping (String, Bool) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onLine = onLine; self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        readers.enter(); readers.enter()
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.readers.wait()
                DispatchQueue.main.async { self.onExit?(process.terminationStatus) }
            }
        }
        do { try process.run() }
        catch { readers.leave(); readers.leave(); throw error }
        read(stdout.fileHandleForReading, stderr: false)
        read(stderr.fileHandleForReading, stderr: true)
    }
    private func read(_ handle: FileHandle, stderr: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { readers.leave(); try? handle.close() }
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    DispatchQueue.main.async { [self] in onLine?(line, stderr) }
                }
                if pending.count > 65536 {
                    let line = String(decoding: pending.prefix(65536), as: UTF8.self)
                    pending.removeAll()
                    DispatchQueue.main.async { [self] in onLine?("[oversized line] " + line, stderr) }
                }
            }
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { [self] in onLine?(line, stderr) }
            }
        }
    }
    func cancel() { if process.isRunning { process.terminate() } }
}
