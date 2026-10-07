import Foundation
import Darwin

private var h3MockStop: Int32 = 0

enum H3Mock {
    static func createRuntime(root: URL, executable: URL) throws -> H3Runtime {
        let fm = FileManager.default; try fm.createDirectory(at: root.appendingPathComponent("candidates"), withIntermediateDirectories: true)
        let helperSHA = try WorkspaceDigest.sha256(executable)
        let value: [String: Any] = ["version": 2, "integration_kind": "native_local_child_process", "requires_http_or_webpage_bridge": false,
            "native_runtime": ["helper_path": executable.path, "helper_sha256": helperSHA, "working_directory": root.path, "memory_cap_mb": 12288, "wired_pool_mb": 8192, "max_generators": 1],
            "native_app_process_contract": ["launcher": "Foundation.Process", "run_existing_single_shot_wrapper": ["executable": "/usr/bin/python3", "arguments": [root.path + "/run_single_shot.py", "--job", "<fresh job>", "--work-dir", root.path, "--run"], "current_directory": root.path]],
            "observed_candidate": ["job": root.path + "/candidates/already-claimed/job.json", "do_not_run_this_job_again": true], "next_generation_authorized": true, "do_not_run_previous_claimed_job": true]
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("mock-contract.json"), options: .withoutOverwriting)
        // These marker scripts are fingerprinted by the same binding code but are
        // never executed. The mock launches only this binary's explicit CPU modes.
        for file in ["run_single_shot.py", "validate_single_shot.py"] { try Data("# CPU mock protocol marker; not executable\n".utf8).write(to: root.appendingPathComponent(file), options: .withoutOverwriting) }
        return .mock(root: root, executable: executable)
    }
    static func createJob(runtime: H3Runtime, scenario: String = "success") throws -> URL {
        guard runtime.mode == .mock else { throw StudioError.invalid("测试构建器不能为真实引擎准备任务。") }
        let id = "mock-" + UUID().uuidString, directory = URL(fileURLWithPath: runtime.workDirectory + "/candidates/" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("record"), withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("reference.png"), pipeline = directory.appendingPathComponent("record/pipeline.vpipeline")
        try Data("synthetic CPU mock reference; no real source image".utf8).write(to: source)
        try Data("{\"mock_cpu_only\":true}".utf8).write(to: pipeline)
        let helper = URL(fileURLWithPath: runtime.executable), sourceSHA = try WorkspaceDigest.sha256(source)
        let job = H3SingleJob(version: 1, job_id: id, shot_number: 15, segment_id: "s15-p01",
            authorization: H3Authorization(user_authorized: true, max_generators: 1, no_automatic_retry: true, no_auto_queue: true),
            work_dir: runtime.workDirectory, output_dir: directory.path, pipeline_path: pipeline.path, clip_path: directory.appendingPathComponent("cpu-mock-candidate.mp4").path,
            helper_path: helper.path, helper_sha256: try WorkspaceDigest.sha256(helper), library_path: helper.path, library_sha256: try WorkspaceDigest.sha256(helper),
            source_image: source.path, source_image_sha256: sourceSHA, model_ref: "local/MiniMax-H3-FL2VA-8bit", lora_ref: "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema", profile: .approved, seed: 1,
            prompt_sha256: String(repeating: "0", count: 64), frozen: [source.path: sourceSHA, pipeline.path: try WorkspaceDigest.sha256(pipeline)], minimum_free_bytes: 1_048_576, max_wall_seconds: 60,
            selected_for_production: false, mock_scenario: scenario)
        let path = directory.appendingPathComponent("job.json"); try JSONEncoder().encode(job).write(to: path, options: .withoutOverwriting); return path
    }
    private static func request(_ url: URL) throws -> (H3WorkerRequest, H3SingleJob) {
        let request = try JSONDecoder().decode(H3WorkerRequest.self, from: H3Files.read(url))
        guard request.binding.runtime.mode == .mock else { throw StudioError.invalid("模拟入口拒绝真实引擎请求。") }
        let job = try JSONDecoder().decode(H3SingleJob.self, from: H3Files.read(URL(fileURLWithPath: request.binding.jobPath)))
        return (request, job)
    }
    static func wrapper(_ url: URL) -> Int32 {
        signal(SIGTERM) { _ in h3MockStop = 1 }; signal(SIGINT) { _ in h3MockStop = 1 }
        var child: H3ChildProcess?; var scope: OwnedProcessScope?
        do {
            let (request, job) = try request(url), fm = FileManager.default
            let output = URL(fileURLWithPath: job.output_dir), root = URL(fileURLWithPath: job.work_dir)
            guard fm.currentDirectoryPath == job.work_dir else { throw StudioError.invalid("mock cwd 不匹配") }
            try Data("one attempt".utf8).write(to: output.appendingPathComponent("attempt-once.json"), options: .withoutOverwriting)
            let logURL = output.appendingPathComponent("record/native-run.log")
            try Data().write(to: logURL, options: .withoutOverwriting)
            let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
            let lock = NSLock(); var latest: String?
            func append(_ text: String) { lock.lock(); defer { lock.unlock() }; try? log.write(contentsOf: Data((text + "\n").utf8)) }
            func state(_ phase: String, native: Int32? = nil, code: Int32? = nil) throws {
                lock.lock(); let progress = latest; lock.unlock()
                let value: [String: Any] = ["status": phase, "job_id": job.job_id, "output_dir": job.output_dir, "clip_path": job.clip_path,
                    "controller_pid": getpid(), "vpipe_pid": native.map { $0 as Any } ?? NSNull(), "native_exit_code": code.map { $0 as Any } ?? NSNull(),
                    "latest_progress": progress.map { $0 as Any } ?? NSNull(), "selected_for_production": false, "simulated": true, "cwd": fm.currentDirectoryPath]
                try JSONSerialization.data(withJSONObject: value).write(to: output.appendingPathComponent("status.json"), options: .atomic)
            }
            try state("starting"); Thread.sleep(forTimeInterval: 0.15)
            if job.mock_scenario == "runner_failure" { append("[ERROR] injected CPU mock runner failure"); try state("failed_no_auto_retry", code: 7); return 7 }
            let nativeOutput = output.appendingPathComponent("native", isDirectory: true)
            try fm.createDirectory(at: nativeOutput, withIntermediateDirectories: false)
            try JSONEncoder().encode(request.sessionID).write(to: root.appendingPathComponent("owner.json"), options: .atomic)
            let fixture = WorkerRequest(jobID: request.appJobID, sessionID: request.sessionID, ownerPID: getpid(), workspace: root.path,
                outputDirectory: nativeOutput.path, fail: false, delay: ["slow", "orphan", "cancel_after_output", "stubborn_controller"].contains(job.mock_scenario ?? "") ? 0.045 : 0.006, ffmpeg: request.ffmpeg)
            let fixturePath = output.appendingPathComponent("fixture-request.json"); try JSONEncoder().encode(fixture).write(to: fixturePath)
            let native = H3ChildProcess(); child = native
            try native.start(executable: URL(fileURLWithPath: request.binding.runtime.executable), arguments: ["--fixture-worker", fixturePath.path], directory: root) { line, stderr in
                if !stderr, let event = try? JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) {
                    if event.type == "progress", let done = event.completed, let total = event.total {
                        let raw = String(format: "[PROGRESS] %.1f%% of 'mock CPU frames' completed at mock (%d/%d)", Double(done) / Double(total) * 100, done, total)
                        lock.lock(); latest = raw; lock.unlock(); append(raw)
                    } else if let stage = event.stage { append("[STAGE] " + stage) }
                } else { append((stderr ? "stderr: " : "stdout: ") + line) }
            }
            let ownership = try OwnedProcessScope(process: native.process); scope = ownership
            if job.mock_scenario == "stubborn_controller" {
                signal(SIGTERM, SIG_IGN)
                while true { ownership.refresh(); try state("generating", native: native.process.processIdentifier); Thread.sleep(forTimeInterval: 0.1) }
            }
            while native.process.isRunning {
                ownership.refresh(); try state("generating", native: native.process.processIdentifier)
                if h3MockStop != 0 {
                    ownership.stop(SIGTERM); Thread.sleep(forTimeInterval: 0.1)
                    if native.process.isRunning { ownership.stop(SIGKILL) }
                    native.process.waitUntilExit(); native.drain(); try state("failed_no_auto_retry", code: 130); return 130
                }
                Thread.sleep(forTimeInterval: 0.08)
            }
            native.process.waitUntilExit(); native.drain()
            guard native.process.terminationStatus == 0 else { try state("failed_no_auto_retry", code: native.process.terminationStatus); return native.process.terminationStatus }
            if job.mock_scenario != "missing_output" { try fm.copyItem(at: nativeOutput.appendingPathComponent("synthetic-candidate.mp4"), to: URL(fileURLWithPath: job.clip_path)) }
            if job.mock_scenario == "cancel_after_output" {
                append("[STAGE] mock output retained while native stage is pending")
                while h3MockStop == 0 { Thread.sleep(forTimeInterval: 0.1) }
                try state("failed_no_auto_retry", code: 130); return 130
            }
            if job.mock_scenario == "orphan" {
                append("[STAGE] mock controller awaits owner")
                while h3MockStop == 0 { Thread.sleep(forTimeInterval: 0.1) }
                try state("failed_no_auto_retry", code: 130); return 130
            }
            append("[PROGRESS] 'mock CPU frames' ended at mock, last reported 100% (48/48)")
            try state("native_completed_pending_validation", code: 0)
            print("{\"status\":\"native_completed_pending_validation\",\"simulated\":true}")
            return 0
        } catch {
            if let child, let scope, child.process.isRunning { scope.stop(SIGTERM); Thread.sleep(forTimeInterval: 0.15); if child.process.isRunning { scope.stop(SIGKILL) }; child.process.waitUntilExit() }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 1
        }
    }
    static func validator(_ url: URL) -> Int32 {
        signal(SIGTERM) { _ in h3MockStop = 1 }; signal(SIGINT) { _ in h3MockStop = 1 }
        do {
            let (request, job) = try request(url)
            guard FileManager.default.currentDirectoryPath == job.work_dir else { throw StudioError.invalid("mock validator cwd 不匹配") }
            Thread.sleep(forTimeInterval: 0.2)
            if job.mock_scenario == "validation_failure" { return 8 }
            if job.mock_scenario == "slow_validation" { for _ in 0..<50 { if h3MockStop != 0 { return 130 }; Thread.sleep(forTimeInterval: 0.1) } }
            let decode = Process(); decode.executableURL = URL(fileURLWithPath: request.ffmpeg)
            decode.arguments = ["-v", "error", "-xerror", "-err_detect", "explode", "-threads", "1", "-i", job.clip_path, "-map", "0:v:0", "-f", "null", "-"]
            decode.standardOutput = FileHandle.nullDevice; decode.standardError = FileHandle.nullDevice
            try decode.run(); decode.waitUntilExit(); guard decode.terminationStatus == 0 else { return 9 }
            let report: [String: Any] = ["status": "technical_pass_visual_review_pending", "job_id": job.mock_scenario == "report_mismatch" ? "another-job" : job.job_id,
                "clip_path": job.clip_path, "clip_sha256": try WorkspaceDigest.sha256(URL(fileURLWithPath: job.clip_path)), "native_exit_code": 0,
                "decoded_video_frames": 48, "dimensions": [384, 224], "fps": 24, "native_lossless_frames": 48,
                "strict_full_av_decode": "pass", "strict_lossless_decode": "pass", "original_frozen_files_unchanged": true,
                "selected_for_production": false, "visual_review": "pending", "simulated": true, "validation_scope": "CPU fixture full video decode; H3 and audio validation are mocked"]
            try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: job.output_dir + "/technical-validation.json"), options: .withoutOverwriting)
            return 0
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); return 1 }
    }
}
