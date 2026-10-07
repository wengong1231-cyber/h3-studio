import Foundation

enum AppIdentity {
    static let name = "镜生 H3"
    static let bundleID = "com.wengong.WanshenjiH3Studio"
    static let executable = "WanshenjiH3Studio"
    static let version = "0.4.26"
    static let buildNumber = "33"
    static let ffmpeg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/ffmpeg").path
    static let originalProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/text2image").path
    static let modelStatusRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex/2026-10-05/task/h3-restore", isDirectory: true)
}

enum EngineKind: String, Codable, CaseIterable {
    case fixture, h3
    var label: String { self == .fixture ? "合成验证 · CPU" : "本地 H3 · 单镜" }
}

enum JobStatus: String, Codable {
    case queued, running, cancelling, completed, failed, cancelled, interrupted, blocked
    var label: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "生成中"
        case .cancelling: return "正在取消"
        case .completed: return "候选已生成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "运行中断"
        case .blocked: return "等待 H3"
        }
    }
    var isActive: Bool { self == .running || self == .cancelling }
    var isPending: Bool { self == .queued || self == .blocked }
    var canCancel: Bool { isPending || self == .running }
    var canRetry: Bool { [.failed, .cancelled, .interrupted].contains(self) }
}

struct StageProgress: Codable, Equatable {
    var completed: Int
    var total: Int
    var unit: String
    var fraction: Double { Double(completed) / Double(max(1, total)) }
    var label: String { "\(completed) / \(total) \(unit)" }
}

struct Attempt: Identifiable, Codable {
    var number: Int
    var startedAt: Date
    var endedAt: Date?
    var status: JobStatus
    var directory: String
    var candidate: String?
    var error: String?
    var peaks = ResourcePeaks()
    var parameters = GenerationParameters()
    var id: Int { number }
}

struct ShotJob: Identifiable, Codable {
    var id = UUID()
    var importKey: String?
    var shot: Int
    var segment: String
    var title: String
    var prompt: String
    var reference: String?
    var lastReference: String?
    var requestedDuration: Double
    var engine: EngineKind
    var status: JobStatus
    var stage = "等待开始"
    var progress: StageProgress?
    var executionActivity: ExecutionActivity?
    var createdAt = Date()
    var updatedAt = Date()
    var startedAt: Date?
    var endedAt: Date?
    var workerPID: Int32?
    var workerIdentity: ProcessIdentity?
    var h3Binding: H3Binding?
    var h3Outcome: H3Outcome?
    var externalHistory: ExternalH3History?
    var h3ABConfiguration: H3ABConfiguration?
    var h3FirstProposal: H3FirstProposal?
    var h3QueuePlan: H3QueuePlan?
    var h3StaticBinding: H3StaticInputBinding?
    var h3VideoReview: H3VideoReviewState?
    var h3ABAcceptance: H3ABAcceptanceState?
    var h3VideoRejection: H3VideoRejectionState?
    var h3FidelityChecks: [H3FidelityRecord]?
    var h3InputRecoveries: [H3IndependentInputRecovery]?
    var supersededBy: UUID?
    var redoOf: UUID?
    var resultRevisionLinks: [ResultRevisionLink]?
    var requiresNewStaticInput: Bool?
    var h3InputPreparation: H3InputPreparation?
    var h3AutomaticWorkflow: H3AutomaticWorkflow?
    var h3GenerationStartedAt: Date?
    var h3GenerationEndedAt: Date?
    var h3ValidationStartedAt: Date?
    var h3ValidationEndedAt: Date?
    var cancellationSource: String?
    var attempts: [Attempt] = []
    var candidate: String?
    var error: String?
    var logTail: [String] = []
    var fixtureFailure = false
    var fixtureDelay: Double = 0.1
    var parameters = GenerationParameters()
    var shortID: String { String(format: "S%02d", shot) }
    var reviewedInputAwaitingLaunch: Bool {
        status.isPending && h3AutomaticWorkflow?.phase == "pixel_qa"
            && h3AutomaticWorkflow?.automaticContinuationAuthorized == true
            && h3FirstProposal?.reviewReady == true
    }
    var displayStatusLabel: String {
        if supersededBy != nil { return "历史 · 已重做" }
        if h3VideoRejection != nil { return h3VideoRejection?.actorKind == "user" ? "用户已拒绝 · 待重做" : "候选已拒绝 · 来源为界面操作" }
        if status == .completed,h3ABAcceptance != nil { return "已接受 · 既有用户指令" }
        if status == .completed,h3VideoReview?.isTrustedAcceptance == true { return h3VideoReview?.provenance?.declaresProductAcceptance == true ? "已接受 · 界面操作" : "接受来源已核对" }
        if status == .completed,h3VideoReview != nil { return "接受来源待核对" }
        if status.isPending,h3FirstProposal != nil,h3AutomaticWorkflow != nil {
            if reviewedInputAwaitingLaunch { return "待启动" }
            return h3AutomaticWorkflow?.phase == "pixel_qa" ? "检查画面" : "准备中"
        }
        if status == .blocked,let plan = h3QueuePlan,h3FirstProposal == nil { return plan.statusLabel }
        return status.label
    }
    var displayStage: String {
        // Old persisted stage text may describe a queue pause that has since
        // been lifted. Keep the audit text, but show current input facts here.
        if reviewedInputAwaitingLaunch { return "画面检查通过 · 输入与回执保留" }
        if h3FirstProposal != nil { return stage }
        if h3ABConfiguration != nil,status.isPending,h3AutomaticWorkflow == nil,h3InputPreparation?.status != "failed" {
            return "就绪后自动处理输入、生成与检查输出"
        }
        if status == .completed,externalHistory == nil {
            return engine == .h3 && h3Outcome?.technicalPass == true ? "自动技术检查通过 · 候选已保存" : "候选已生成"
        }
        return stage
    }
    var canRetryInApp: Bool { engine == .fixture && status.canRetry }
    var canCancelInApp: Bool { externalHistory == nil && status.canCancel }
    var elapsed: Double { max(0, (endedAt ?? Date()).timeIntervalSince(startedAt ?? endedAt ?? Date())) }
    var elapsedLabel: String {
        guard startedAt != nil else { return "—" }
        let seconds = Int(elapsed)
        return seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
    }
    static func fixture(shot: Int, title: String, failure: Bool = false, delay: Double = 0.1) -> ShotJob {
        var job = ShotJob(shot: shot, segment: String(format: "s%02d-fixture", shot), title: title,
                          prompt: "合成验证：生成 48 帧程序化山峦与日月轨迹。用于验证任务进度与候选预览，不是 H3 生成结果。",
                          requestedDuration: 2, engine: .fixture, status: .queued)
        job.fixtureFailure = failure
        job.fixtureDelay = delay
        return job
    }
}

struct WorkspaceState: Codable {
    var version = 1
    var queuePaused = true
    var automaticLaunchesPaused: Bool?
    var jobs: [ShotJob] = []
    var theme = "system"
    var orbX: Double?
    var orbY: Double?
    var monitoring = true
    var samplingInterval: Double = 5
    var h3StaticCatalogs: [H3StaticCatalog]?
}

struct GenerationParameters: Codable {
    var width: Int? = 384
    var height: Int? = 224
    var frames: Int? = 48
    var steps: Int?
    var fps: Double? = 24
    var model = "CPU synthetic fixture v1"
    var verified = true
    var resolutionLabel: String { if let width, let height { return "\(width) × \(height)" }; return "待引擎确认" }
}

struct ResourcePeaks: Codable {
    var systemCPU: Double?
    var systemGPU: Double?
    var gpuSharedSystemMemoryMB: Double?
    var appFootprintMB: Double?
    var workerRSSMB: Double?
    var samples = 0
    mutating func include(_ sample: ResourceSample, gpuSince: Date? = nil) {
        func peak(_ previous: Double?, _ current: Double?) -> Double? {
            guard let current else { return previous }
            return max(previous ?? 0, current)
        }
        systemCPU = peak(systemCPU, sample.cpuPercent)
        if let gpu = sample.gpu, gpuSince == nil || gpu.timestamp >= gpuSince! {
            systemGPU = peak(systemGPU, gpu.utilizationPercent)
            gpuSharedSystemMemoryMB = peak(gpuSharedSystemMemoryMB, gpu.sharedSystemMemoryMB)
        }
        appFootprintMB = peak(appFootprintMB, sample.appFootprintMB)
        workerRSSMB = peak(workerRSSMB, sample.workerRSSMB)
        samples += 1
    }
}

struct WorkerRequest: Codable {
    var version = 1
    var jobID: UUID
    var sessionID: UUID
    var ownerPID: Int32
    var workspace: String
    var outputDirectory: String
    var fail: Bool
    var delay: Double
    var ffmpeg: String
}

struct EngineEvent: Codable {
    var type: String
    var stage: String?
    var completed: Int?
    var total: Int?
    var unit: String?
    var path: String?
    var message: String?
    var childPID: Int32?
    var ownedProcesses: [ProcessIdentity]?
    var reportPath: String?
    var simulated: Bool?
}

enum StudioError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

enum ManifestImporter {
    static func parse(_ data: Data, url: URL) throws -> [ShotJob] {
        guard data.count <= 12 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioError.invalid("需要小于 12 MB 的镜头 JSON manifest。")
        }
        guard let rows = (root["jobs"] ?? root["shots"]) as? [[String: Any]], !rows.isEmpty else {
            throw StudioError.invalid("未找到 shots 或 jobs 镜头列表。")
        }
        var jobs: [ShotJob] = []
        for row in rows {
            let parts = row["segments"] as? [[String: Any]] ?? [row]
            for part in parts {
                let shot = (part["shot_number"] ?? part["shot"] ?? row["number"] ?? row["shot"]) as? Int ?? jobs.count + 1
                let segment = part["id"] as? String ?? String(format: "s%02d", shot)
                let title = row["title"] as? String ?? row["label"] as? String ?? segment
                let prompt = part["prompt"] as? String ?? row["prompt"] as? String ?? ""
                guard (1...10000).contains(shot), prompt.utf8.count <= 80000, segment.utf8.count < 512,
                      title.utf8.count < 2048 else { throw StudioError.invalid("镜头编号、名称或提示词超出范围。") }
                func resolve(_ value: Any?) throws -> String? {
                    guard let path = value as? String, !path.isEmpty else { return nil }
                    let result = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.deletingLastPathComponent().appendingPathComponent(path)
                    let normalized = result.standardizedFileURL
                    guard !normalized.pathComponents.contains("sessions"), !normalized.resolvingSymlinksInPath().pathComponents.contains("sessions") else { throw StudioError.invalid("不导入 sessions 目录中的引用。") }
                    return normalized.path
                }
                let reference = try resolve(part["first"] ?? part["source_image"] ?? row["source_image"])
                let last = try resolve(part["last"] ?? part["last_frame"])
                let duration = (part["used_duration_seconds"] ?? row["target_duration_seconds"] ?? row["duration"]) as? Double ?? 5.167
                guard duration.isFinite, duration > 0, duration <= 600 else { throw StudioError.invalid("镜头时长无效。") }
                var job = ShotJob(shot: shot, segment: segment, title: title, prompt: prompt, reference: reference,
                                  lastReference: last, requestedDuration: duration, engine: .h3, status: .blocked)
                job.importKey = url.standardizedFileURL.path + "|" + segment + "|" + (reference ?? "")
                job.stage = "等待核准的 H3 引擎契约"
                let profile = root["profile"] as? [String: Any] ?? [:]
                job.parameters = GenerationParameters(width: profile["width"] as? Int, height: profile["height"] as? Int,
                    frames: (part["generation_frames"] ?? part["frames"] ?? row["generation_frames"] ?? profile["frames"]) as? Int,
                    steps: profile["steps"] as? Int, fps: profile["fps"] as? Double,
                    model: root["model_family"] as? String ?? "MiniMax H3 · 版本待核准", verified: false)
                // Production output_clip, clip and pipeline values are deliberately never used as destinations.
                jobs.append(job)
                guard jobs.count <= 500 else { throw StudioError.invalid("一次最多导入 500 个镜头。") }
            }
        }
        return jobs
    }
}
