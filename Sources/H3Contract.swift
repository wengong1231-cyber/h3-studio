import Foundation
import Darwin

struct ProcessIdentity: Codable, Equatable {
    var pid: Int32
    var parentPID: Int32
    var startedSeconds: UInt64
    var startedMicroseconds: UInt64
    static func capture(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Self(pid: pid, parentPID: Int32(info.pbi_ppid), startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }
    var stillSameProcess: Bool {
        guard let current = Self.capture(pid) else { return false }
        return current.pid == pid && current.startedSeconds == startedSeconds && current.startedMicroseconds == startedMicroseconds
    }
    func signal(_ value: Int32) { if stillSameProcess { kill(pid, value) } }
}

enum H3Files {
    static func safe(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path, url.resolvingSymlinksInPath().path == path, !url.pathComponents.contains("sessions") else { throw StudioError.invalid("单镜路径不能含跳转、符号链接或 sessions。") }
        return url
    }
    static func read(_ url: URL, limit: Int = 12_582_912) throws -> Data {
        _ = try safe(url.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= limit else { throw StudioError.invalid("单镜记录不是普通文件或超过读取上限。") }
        return try Data(contentsOf: url)
    }
    static func inside(_ path: String, _ root: String) throws -> URL {
        let url = try safe(path); _ = try safe(root)
        guard path.hasPrefix(root + "/") else { throw StudioError.invalid("单镜输出必须属于已绑定的独立候选目录。") }
        return url
    }
}

struct H3Profile: Codable, Equatable {
    var width: Int; var height: Int; var frames: Int; var fps: Int; var steps: Int
    var memory_cap_mb: Int; var wired_pool_mb: Int
    static let approved = Self(width: 768, height: 448, frames: 124, fps: 24, steps: 4, memory_cap_mb: 12288, wired_pool_mb: 8192)
    static let s41AB = Self(width: 768, height: 448, frames: 73, fps: 24, steps: 4, memory_cap_mb: 12288, wired_pool_mb: 8192)
    static let s19First = Self(width: 768, height: 448, frames: 90, fps: 24, steps: 4, memory_cap_mb: 12288, wired_pool_mb: 8192)
}
struct H3Authorization: Codable {
    var user_authorized: Bool; var max_generators: Int; var no_automatic_retry: Bool; var no_auto_queue: Bool
}
struct H3SingleJob: Codable {
    var version: Int; var job_id: String; var shot_number: Int; var segment_id: String
    var authorization: H3Authorization
    var work_dir: String; var output_dir: String; var pipeline_path: String; var clip_path: String
    var helper_path: String; var helper_sha256: String
    var library_path: String; var library_sha256: String
    var source_image: String; var source_image_sha256: String
    var model_ref: String; var lora_ref: String; var profile: H3Profile; var seed: Int
    var prompt_sha256: String; var frozen: [String: String]
    var minimum_free_bytes: Int64; var max_wall_seconds: Double
    var selected_for_production: Bool
    var mock_scenario: String?
    var app_ab_task: H3ABTaskBinding? = nil
    var app_first_task: H3FirstTaskBinding? = nil
    var last_source_image: String? = nil
    var last_source_image_sha256: String? = nil
}
struct H3NativeContract: Decodable {
    struct Runtime: Decodable { var helper_path: String; var helper_sha256: String; var working_directory: String; var memory_cap_mb: Int; var wired_pool_mb: Int; var max_generators: Int }
    struct ProcessContract: Decodable {
        struct Wrapper: Decodable { var executable: String; var arguments: [String]; var current_directory: String }
        var launcher: String; var run_existing_single_shot_wrapper: Wrapper
    }
    struct Candidate: Decodable { var job: String; var do_not_run_this_job_again: Bool }
    var version: Int; var integration_kind: String; var requires_http_or_webpage_bridge: Bool
    var native_runtime: Runtime; var native_app_process_contract: ProcessContract
    var observed_candidate: Candidate; var next_generation_authorized: Bool; var do_not_run_previous_claimed_job: Bool
}

struct H3Runtime: Codable, Equatable {
    enum Mode: String, Codable { case real, mock }
    var mode: Mode
    var contractPath: String
    var workDirectory: String
    var executable: String
    static var real: Self {
        let work = AppIdentity.modelStatusRoot.path
        return Self(mode: .real, contractPath: work + "/single-shot-native-app-contract-v2.json", workDirectory: work, executable: "/usr/bin/python3")
    }
    static func mock(root: URL, executable: URL) -> Self { Self(mode: .mock, contractPath: root.appendingPathComponent("mock-contract.json").path, workDirectory: root.path, executable: executable.path) }
}

struct H3Binding: Codable, Equatable {
    var runtime: H3Runtime
    var jobPath: String; var jobSHA256: String; var contractSHA256: String
    var runnerSHA256: String; var validatorSHA256: String
    var nativeJobID: String; var outputDirectory: String; var clipPath: String
    var profile: H3Profile; var minimumFreeBytes: Int64
    var executionAuthorized: Bool
    var appABTask: H3ABTaskBinding? = nil
    var appFirstTask: H3FirstTaskBinding? = nil
    var appTaskID: UUID? { appABTask?.appJobID ?? appFirstTask?.appJobID }
    var appTaskWorkspace: String? { appABTask?.appWorkspace ?? appFirstTask?.appWorkspace }
    var runnerPath: String { runtime.workDirectory + "/run_single_shot.py" }
    var validatorPath: String { runtime.workDirectory + "/validate_single_shot.py" }
    var nativeLog: URL { URL(fileURLWithPath: outputDirectory + "/record/native-run.log") }
    var nativeStatus: URL { URL(fileURLWithPath: outputDirectory + "/status.json") }
    static func load(_ url: URL, runtime: H3Runtime, requireFresh: Bool = true) throws -> (Self, H3SingleJob) {
        let preliminary = try JSONDecoder().decode(H3SingleJob.self, from: H3Files.read(url))
        if preliminary.app_ab_task != nil { return try H3ABTaskBinding.load(url, runtime: runtime, requireFresh: requireFresh) }
        if preliminary.app_first_task != nil { return try H3FirstTaskBinding.load(url,runtime:runtime,requireFresh:requireFresh) }
        let fm = FileManager.default
        let contractURL = try H3Files.safe(runtime.contractPath)
        let contract = try JSONDecoder().decode(H3NativeContract.self, from: H3Files.read(contractURL))
        let template = contract.native_app_process_contract.run_existing_single_shot_wrapper
        guard contract.version == 2, contract.integration_kind == "native_local_child_process", !contract.requires_http_or_webpage_bridge,
              contract.native_app_process_contract.launcher == "Foundation.Process", contract.native_runtime.max_generators == 1,
              contract.native_runtime.memory_cap_mb == 12288, contract.native_runtime.wired_pool_mb == 8192,
              contract.native_runtime.working_directory == runtime.workDirectory, template.current_directory == runtime.workDirectory,
              template.arguments.count == 6, template.arguments[0] == runtime.workDirectory + "/run_single_shot.py",
              template.arguments[1] == "--job", template.arguments[3] == "--work-dir", template.arguments[4] == runtime.workDirectory, template.arguments[5] == "--run",
              contract.do_not_run_previous_claimed_job, contract.observed_candidate.do_not_run_this_job_again,
              template.executable == "/usr/bin/python3" else { throw StudioError.invalid("原生单镜契约与核准的 v2 启动参数不匹配。") }
        if runtime.mode == .real { guard runtime == .real, contract.native_runtime.helper_path == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Helpers/vpipe" else { throw StudioError.invalid("真实单镜运行位置必须使用父任务核准路径。") } }
        _ = try H3Files.safe(runtime.workDirectory)
        _ = try H3Files.inside(url.path, runtime.workDirectory + "/candidates")
        guard !(contract.do_not_run_previous_claimed_job && url.path == contract.observed_candidate.job), !contract.observed_candidate.job.isEmpty else { throw StudioError.invalid("已生成的首镜已领取，不能再次投递。请绑定新的已授权单镜。") }
        let data = try H3Files.read(url)
        let job = try JSONDecoder().decode(H3SingleJob.self, from: data)
        if fm.fileExists(atPath: contract.observed_candidate.job) {
            let observedURL = try H3Files.inside(contract.observed_candidate.job, runtime.workDirectory + "/candidates")
            let observed = try JSONSerialization.jsonObject(with: H3Files.read(observedURL)) as? [String: Any]
            guard observed?["job_id"] as? String != job.job_id else { throw StudioError.invalid("此单镜身份属于已领取的首镜，换文件位置也不能重投。") }
        }
        guard job.version == 1, job.shot_number == 15, job.segment_id == "s15-p01", job.profile == .approved,
              job.authorization.user_authorized, job.authorization.max_generators == 1, job.authorization.no_automatic_retry, job.authorization.no_auto_queue,
              job.work_dir == runtime.workDirectory, job.model_ref == "local/MiniMax-H3-FL2VA-8bit", job.lora_ref == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",
              job.helper_path == contract.native_runtime.helper_path, job.helper_sha256 == contract.native_runtime.helper_sha256,
              !job.selected_for_production, (1...3600).contains(job.max_wall_seconds), !job.job_id.isEmpty, job.job_id.utf8.count < 512,
              runtime.mode == .mock || job.mock_scenario == nil, runtime.mode == .mock || job.minimum_free_bytes >= 20 * 1_073_741_824 else { throw StudioError.invalid("单镜授权、模型、参数或资源边界不匹配；未投递。") }
        _ = try H3Files.inside(job.output_dir, runtime.workDirectory + "/candidates")
        guard url.path == job.output_dir + "/job.json" else { throw StudioError.invalid("任务文件必须位于其独立候选目录。") }
        _ = try H3Files.inside(job.pipeline_path, job.output_dir)
        _ = try H3Files.inside(job.clip_path, job.output_dir)
        _ = try H3Files.safe(job.source_image); _ = try H3Files.safe(job.library_path)
        if runtime.mode == .real {
            _ = try H3Files.inside(job.source_image, AppIdentity.originalProject + "/assets")
            guard job.library_path == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Frameworks/libvpipe.0.dylib" else { throw StudioError.invalid("原生动态库位置不匹配。") }
        }
        guard job.frozen[job.pipeline_path] != nil, job.frozen[job.source_image] == job.source_image_sha256, job.frozen.count <= 100 else { throw StudioError.invalid("单镜缺少冻结输入与隔离管线绑定。") }
        for (path, hash) in job.frozen {
            _ = try H3Files.safe(path)
            let allowed = path.hasPrefix(job.output_dir + "/") || (runtime.mode == .real && ["assets", "outputs", "video"].contains { path.hasPrefix(AppIdentity.originalProject + "/" + $0 + "/") })
            guard allowed, !URL(fileURLWithPath: path).pathComponents.contains(where: { $0.hasPrefix(".") || ["credentials", "secrets"].contains($0.lowercased()) }), hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw StudioError.invalid("冻结输入超出核准引用范围或指纹无效。") }
        }
        guard try WorkspaceDigest.sha256(try H3Files.inside(job.pipeline_path, job.output_dir)) == job.frozen[job.pipeline_path] else { throw StudioError.invalid("已绑定管线发生变化，不能投递。") }
        if requireFresh {
            for path in [job.clip_path, job.output_dir + "/attempt-once.json", job.output_dir + "/status.json", job.output_dir + "/technical-validation.json", job.output_dir + "/record/native-run.log"] {
                _ = try H3Files.inside(path, job.output_dir)
                guard !fm.fileExists(atPath: path) else { throw StudioError.invalid("单镜候选已占用或已投递，不会覆盖或重跑。") }
            }
        }
        let runner = try H3Files.safe(runtime.workDirectory + "/run_single_shot.py")
        let validator = try H3Files.safe(runtime.workDirectory + "/validate_single_shot.py")
        _ = try H3Files.read(runner); _ = try H3Files.read(validator)
        return (Self(runtime: runtime, jobPath: url.path, jobSHA256: try WorkspaceDigest.sha256(url), contractSHA256: try WorkspaceDigest.sha256(contractURL),
            runnerSHA256: try WorkspaceDigest.sha256(runner), validatorSHA256: try WorkspaceDigest.sha256(validator), nativeJobID: job.job_id,
            outputDirectory: job.output_dir, clipPath: job.clip_path, profile: job.profile, minimumFreeBytes: job.minimum_free_bytes, executionAuthorized: contract.next_generation_authorized), job)
    }
    func revalidate() throws -> H3SingleJob {
        let (current, job) = try Self.load(URL(fileURLWithPath: jobPath), runtime: runtime)
        guard current == self else { throw StudioError.invalid("单镜任务或执行契约绑定已变化，需要重新审查，未投递。") }
        return job
    }
    func requireExecutionAuthorization() throws {
        if let first = appFirstTask {
            guard first.proposal.launchAuthorized,first.proposal.reviewReady,
                  first.proposal.pixelReview?.appJobID == first.appJobID else { throw StudioError.invalid("首帧画面检查与本次任务尚未完成绑定。") }
            return
        }
        if let ab = appABTask {
            guard ab.configuration.launchAuthorized, ab.configuration.blockers.isEmpty else { throw StudioError.invalid("S41 A/B 配置尚未齐备或本次生成未放行。") }
            return
        }
        guard runtime.mode == .real else { return }
        let contract = try JSONDecoder().decode(H3NativeContract.self, from: H3Files.read(URL(fileURLWithPath: runtime.contractPath)))
        guard contract.next_generation_authorized else { throw StudioError.invalid("当前契约仍标记下一次真实生成未授权。请由父任务核准新的单镜与契约后再启动。") }
    }
}

enum H3LaunchApproval { case userConfirmed(String), mockForTests(String) }

struct H3DispatchReceipt: Codable {
    var version = 1; var jobSHA256: String; var nativeJobID: String; var appJobID: UUID
    var sessionID: UUID; var reservedAt = Date(); var supervisor: ProcessIdentity?
    var proposalID: String? = nil
    var nativeFrames: Int? = nil
    var editorialFrames: Int? = nil
    var inputSHA256s: [String:String]? = nil
}
struct H3WorkerRequest: Codable {
    var version = 1; var appJobID: UUID; var sessionID: UUID; var owner: ProcessIdentity
    var workspace: String; var attemptDirectory: String; var binding: H3Binding; var ffmpeg: String
}
struct H3Outcome: Codable {
    var technicalPass: Bool; var visualReview = "pending"; var selectedForProduction = false
    var reportPath: String; var simulated: Bool
}
