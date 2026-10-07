import Foundation

enum ExecutionPhase: String, Codable {
    case preparing, starting, loading, sampling, decoding, encoding, validating, checkingInput
    case queued, blocked, cancelling, completed, cancelled, failed, interrupted, processing
    static func from(_ stage: String) -> Self {
        let s = stage.lowercased()
        if s.contains("阶段结束") { return .starting }
        if s.contains("加载") || s.contains("loading") || s.contains("load model") { return .loading }
        if s.contains("采样") || s.contains("sampling") || s.contains("denois") { return .sampling }
        if s.contains("质检") || s.contains("检查原生") || s.contains("验证") || s.contains("validation") { return .validating }
        if s.contains("编码") || s.contains("封装") || s.contains("encoding") || s.contains("mux") { return .encoding }
        if s.contains("解码") || s.contains("decod") { return .decoding }
        if s.contains("画面完整性检查") || s.contains("画面与提示词") { return .checkingInput }
        if s.contains("源帧") || s.contains("归一") || s.contains("素材") || s.contains("输入") || s.contains("预处理") || s.contains("prepare") { return .preparing }
        if s.contains("启动") || s.contains("start") { return .starting }
        return .processing
    }
    var label: String {
        switch self {
        case .preparing: return "准备素材"
        case .starting: return "启动引擎"
        case .loading: return "加载模型"
        case .sampling: return "采样生成"
        case .decoding: return "解码视频"
        case .encoding: return "编码与封装"
        case .validating: return "检查输出"
        case .checkingInput: return "等待助手画面检查"
        case .queued: return "排队 · 尚未开始"
        case .blocked: return "等待条件就绪"
        case .cancelling: return "正在取消"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .processing: return "引擎处理中"
        }
    }
    var quietLimit: TimeInterval { self == .loading ? 120 : [.encoding,.decoding,.validating].contains(self) ? 60 : 45 }
}

/// Persisted business evidence is separate from log traffic, process liveness,
/// resource sampling and UI timers. Legacy records leave this optional.
struct ExecutionActivity: Codable, Equatable {
    var phase: ExecutionPhase
    var rawStage: String
    var phaseStartedAt: Date
    var lastProgressAt: Date?
    var lastProgressNote: String?
    var lastHeartbeatAt: Date?
    var heartbeatSource: String?
    var endedAt: Date?
    var lastCount: Int?
    var lastTotal: Int?

    init(stage: String,at: Date) {
        phase = .from(stage);rawStage = stage;phaseStartedAt = at
        lastProgressAt = at;lastProgressNote = "进入阶段：" + stage
    }
    mutating func milestone(_ stage: String,at: Date,phase explicit: ExecutionPhase? = nil) {
        let phase = explicit ?? .from(stage)
        if rawStage != stage || self.phase != phase {
            self.phase = phase;rawStage = stage;phaseStartedAt = at;lastCount = nil;lastTotal = nil
            if ![.cancelling,.cancelled,.failed,.interrupted,.queued,.blocked].contains(phase) {
                lastProgressAt = at;lastProgressNote = "进入阶段：" + stage
            }
        }
    }
    mutating func observe(_ event: EngineEvent,at: Date) {
        guard endedAt == nil else { return }
        if event.type == "owned",event.ownedProcesses?.isEmpty == false {
            lastHeartbeatAt = at;heartbeatSource = "监督器";return
        }
        if event.type == "heartbeat" {
            lastHeartbeatAt = at;heartbeatSource = "引擎";return
        }
        if event.type == "log" { return }
        if event.type == "progress" {
            guard let count = event.completed,let total = event.total,(1...1_073_741_824).contains(total),(0...total).contains(count) else { return }
            let stage = event.stage ?? rawStage
            if stage == rawStage,lastTotal == total,let previous = lastCount,count <= previous { return }
            milestone(stage,at:at)
            lastCount = count;lastTotal = total;lastProgressAt = at
            lastProgressNote = "\(count) / \(total) \(event.unit ?? "阶段单位")";return
        }
        switch event.type {
        case "stage": if let stage = event.stage { milestone(stage,at:at) }
        case "native_started": milestone("原生进程已启动 · 等待阶段上报",at:at,phase:.starting)
        case "validation_started": milestone("原生输出已写出 · 开始技术检查",at:at,phase:.validating)
        case "prepared_original","prepared_normalized","output","partial_output","technical_pass":
            lastProgressAt = at;lastProgressNote = event.type == "technical_pass" ? "技术检查通过" : "实际产物已写出"
        default: break
        }
    }
    mutating func finish(_ status: JobStatus,stage: String,at: Date) {
        let phase: ExecutionPhase = status == .completed ? .completed : status == .cancelled ? .cancelled : status == .interrupted ? .interrupted : .failed
        milestone(stage,at:at,phase:phase);endedAt = at
    }
}

enum ActivityTone: String { case working, waiting, attention, success, failure }
struct ActivityPresentation {
    var state: String
    var stage: String
    var detail: String
    var elapsed: String
    var stageElapsed: String? = nil
    var lastProgress: String
    var heartbeat: String? = nil
    var nextStep: String? = nil
    var tone: ActivityTone
    var progress: StageProgress? = nil
    var symbol: String
    var shortState: String
}

enum ActivityPresenter {
    static func duration(_ seconds: TimeInterval) -> String {
        let n = Int(max(0,seconds));return n >= 3600 ? "\(n / 3600)小时\(n % 3600 / 60)分" : n >= 60 ? "\(n / 60)分\(n % 60)秒" : "\(n)秒"
    }
    static func age(_ date: Date?,now: Date) -> String {
        guard let date else { return "未记录" }
        return duration(now.timeIntervalSince(date)) + "前"
    }
    static func job(_ job: ShotJob,now: Date) -> ActivityPresentation {
        let a = job.executionActivity,end = job.endedAt ?? a?.endedAt ?? now
        let elapsed = (job.h3AutomaticWorkflow?.startedAt ?? job.startedAt).map { duration(end.timeIntervalSince($0)) } ?? "未开始"
        let last = a?.lastProgressAt.map { "最后真实进展 " + $0.formatted(date:.omitted,time:.standard) + " · " + age($0,now:end) } ?? "真实进展时间未上报"
        let heart = a?.lastHeartbeatAt.map { (a?.heartbeatSource ?? "进程") + "心跳 " + age($0,now:end) }
        let stageElapsed = a.map { "本阶段 " + duration(end.timeIntervalSince($0.phaseStartedAt)) }
        var p = ActivityPresentation(state:"执行中",stage:job.displayStage,detail:"仅显示引擎实际上报的当前阶段。",elapsed:elapsed,stageElapsed:stageElapsed,lastProgress:last,heartbeat:heart,nextStep:nil,tone:.working,progress:job.progress,symbol:"waveform.path",shortState:"运行")
        switch job.status {
        case .completed:
            p.state = "已完成 · 候选已保存";p.shortState = "完成";p.tone = .success;p.symbol = "checkmark.circle.fill";p.progress = nil
            p.detail = "本次耗时已停止计时。候选、日志和检查记录保留。";return p
        case .failed,.interrupted,.cancelled:
            p.state = job.status.label;p.shortState = job.status == .failed ? "失败" : job.status == .interrupted ? "中断" : "取消"
            p.tone = job.status == .failed ? .failure : .attention;p.symbol = job.status == .cancelled ? "stop.circle" : "exclamationmark.circle"
            p.detail = job.error ?? "执行已停止，已完成的输出保留。";p.progress = nil
            p.nextStep = job.status == .interrupted ? "查看原日志与候选；未自动重投。" : job.canRetryInApp ? "查看错误后可重试，原产物保留。" : "查看原日志与候选；需要修复输入或新的任务。";return p
        case .cancelling:
            p.state = "取消请求已发 · 等待自有进程退出";p.shortState = "取消中";p.tone = .attention;p.symbol = "stop.circle";p.progress = nil
            p.detail = "已完成和部分输出继续保留。";p.nextStep = "等待监督器结束本任务，不会停止其他应用。";return p
        case .queued,.blocked:
            if job.h3Binding?.executionAuthorized == false || job.h3FirstProposal?.launchAuthorized == false {
                p.state = "等待本任务生成授权";p.shortState = "待授权";p.stage = "授权尚未确认";p.tone = .waiting;p.symbol = "lock"
                p.detail = "当前任务未授权执行，没有加载模型或启动生成。";p.nextStep = "保持等待，查看本任务契约与日志。";p.progress = nil;return p
            }
            if job.h3AutomaticWorkflow?.phase == "pixel_qa" {
                p.state = "等待助手画面检查";p.shortState = "待检查";p.stage = job.stage;p.tone = .waiting;p.symbol = "eye"
                p.detail = "实际图片已准备，当前没有运行视频生成。";p.nextStep = "助手检查实际图片及提示词后，App自动接续一次。";p.progress = nil;return p
            }
            if job.h3AutomaticWorkflow?.status == "running" || job.h3InputPreparation?.status == "running" { break }
            p.state = job.h3QueuePlan?.dependencyRequestID != nil ? "等待前段 · 尚未启动" : "排队 / 待准备 · 尚未启动"
            p.shortState = job.h3QueuePlan?.dependencyRequestID != nil ? "待前段" : "待准备";p.tone = .waiting;p.symbol = "clock";p.progress = nil
            p.detail = job.error ?? job.h3QueuePlan?.blocker ?? "尚未领取生成任务，没有正在运行的生成进程。"
            p.nextStep = job.h3QueuePlan?.dependencyRequestID != nil ? "完成前段窗口与端点检查后，才能准备本段。" : "选择本任务并准备实际输入。";return p
        case .running: break
        }
        let phase = a?.phase ?? .from(job.stage)
        p.stage = phase.label + (job.stage == phase.label ? "" : " · " + job.stage)
        if job.progress == nil { p.detail = "此阶段未提供可计算进度；不估算百分比。" }
        guard let a else { p.detail += " 此旧记录未保存进展时点，不能据此判断停滞。";return p }
        let quiet = now.timeIntervalSince(a.lastProgressAt ?? a.phaseStartedAt)
        let freshHeartbeat = a.lastHeartbeatAt.map { now.timeIntervalSince($0) <= 30 } == true
        if quiet >= phase.quietLimit {
            p.state = freshHeartbeat ? "暂无新进展 · 监督器仍在上报" : "暂无新进展 · 未收到近期心跳"
            p.shortState = "无进展";p.tone = .attention;p.symbol = "exclamationmark.triangle"
            p.nextStep = "查看本阶段日志；未据此认定卡死，也不会自动重试。"
        } else if freshHeartbeat,job.progress == nil {
            p.state = phase.label + " · 收到监督心跳";p.shortState = phase == .loading ? "加载" : "运行"
        } else { p.state = phase.label + "进行中";p.shortState = phase == .loading ? "加载" : phase == .sampling ? "采样" : "运行" }
        return p
    }
}

struct ModelReadObservation: Equatable {
    var startedAt: Date
    var operation: String
    var file: String?
    var lastStepAt: Date
    var endedAt: Date?
}
final class ModelReadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ModelReadObservation?
    var snapshot: ModelReadObservation? { lock.lock();defer { lock.unlock() };return value }
    func begin(at: Date = Date()) { lock.lock();defer { lock.unlock() };value = .init(startedAt:at,operation:"读取恢复状态",lastStepAt:at) }
    func step(_ operation: String,_ file: String? = nil,at: Date = Date()) {
        lock.lock();defer { lock.unlock() }
        guard var current = value else { return }
        if current.operation != operation || current.file != file { current.operation = operation;current.file = file;current.lastStepAt = at;value = current }
    }
    func finish(at: Date = Date()) { lock.lock();defer { lock.unlock() };value?.endedAt = at }
}
