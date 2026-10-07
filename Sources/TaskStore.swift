import Foundation
import Combine
import Darwin

@MainActor final class TaskStore: ObservableObject {
    @Published var state: WorkspaceState
    @Published var selectedID: UUID?
    @Published var navigationIntent: TaskNavigationIntent?
    @Published var navigationBackStack: [TaskNavigationLocation] = []
    @Published var notice: String?
    @Published var storageFault: String?
    @Published var recoveredPIDs: [Int32] = []
    let root: URL
    let executable: URL
    let locations: ExternalLocations
    let h3Runtime: H3Runtime
    let sessionID = UUID()
    let telemetry: TelemetryMonitor
    let readiness: ModelReadinessMonitor
    let startupLog: StartupPhaseLog
    private let statusMonitoringAllowed: Bool
    private var lockFD: Int32 = -1
    private var runner: ProcessRunner?
    private var childPID: Int32?
    private var h3OwnedProcesses: [ProcessIdentity] = []
    private var recoveredH3Identities: [Int32: ProcessIdentity] = [:]
    private var logHandle: FileHandle?
    private var pendingOutput: String?
    private var heartbeat: Timer?
    var historyTimer: Timer?
    var historyImportInFlight = false {
        didSet {
            if historyImportInFlight && !oldValue { historyReadStartedAt = Date() }
            if !historyImportInFlight { historyReadStartedAt = nil }
            if oldValue && !historyImportInFlight { objectWillChange.send() }
        }
    }
    var historyReadStartedAt: Date?
    var firstReviewTimer: Timer?
    var firstReviewInFlight = false
    var videoReviewRefreshInFlight = false {
        didSet {
            if videoReviewRefreshInFlight && !oldValue { videoReviewReadStartedAt = Date() }
            if !videoReviewRefreshInFlight { videoReviewReadStartedAt = nil }
            if oldValue && !videoReviewRefreshInFlight { objectWillChange.send() }
        }
    }
    var videoReviewReadStartedAt: Date?
    private var backgroundReadWasVisible = false
    func backgroundReadVisible(at now: Date = Date()) -> Bool {
        [historyReadStartedAt, videoReviewReadStartedAt].compactMap { $0 }
            .contains { now.timeIntervalSince($0) >= 1 }
    }
    @Published var abConfigurationBusy = false {
        didSet { if abConfigurationBusy && !oldValue { configurationReadStartedAt = Date() };if !abConfigurationBusy { configurationReadStartedAt = nil } }
    }
    var configurationReadStartedAt: Date?
    var configurationReadOperation = "核对任务配置"
    var abPreparationID: UUID?
    var abPreparationControl: H3PreparationControl?
    @Published var actionRevisionID: UUID?
    var actionRevisionControl: H3PreparationControl?
    @Published var abWorkflowID: UUID?
    var shuttingDown = false
    var launchCount = 0
    var activeJob: ShotJob? { state.jobs.first(where: { $0.status.isActive && $0.externalHistory == nil }) }
    var observedJob: ShotJob? { state.jobs.first(where: { $0.externalHistory?.observing == true }) }
    var ownedActiveTask: ShotJob? { activeJob ?? state.jobs.first(where:{ $0.id == abWorkflowID || ($0.id == abPreparationID && ["running","cancelled"].contains($0.h3InputPreparation?.status ?? "")) }) }
    var displayedActiveJob: ShotJob? { ownedActiveTask ?? observedJob }
    var selected: ShotJob? { state.jobs.first(where: { $0.id == selectedID }) }
    var queuedCount: Int { state.jobs.filter { $0.status == .queued }.count }
    var pendingCount: Int { state.jobs.filter { $0.status.isPending }.count }
    var completedCount: Int { state.jobs.filter { $0.status == .completed }.count }
    var failedCount: Int { state.jobs.filter { [.failed, .interrupted].contains($0.status) }.count }
    static let replacementShots: Set<Int> = [5,9,10,14,19,21,24,26,30,31,35,36,37,38,41,42,44,45]
    var currentVideoSegments: [ShotJob] {
        state.jobs.filter { $0.engine == .h3 && $0.externalHistory == nil && $0.supersededBy == nil
            && Self.replacementShots.contains($0.shot) && ($0.h3QueuePlan != nil || $0.h3ABConfiguration != nil) }
    }
    var replacementShotCount: Int { Set(currentVideoSegments.map(\.shot)).count }
    var currentVideoSegmentCount: Int { currentVideoSegments.count }
    var staticImageCount: Int { Set(staticAssets.map(\.sha256)).count }
    var generatorResourcesIdle: Bool { !shuttingDown && !abConfigurationBusy && !historyImportInFlight && !videoReviewRefreshInFlight && observedJob == nil && runner == nil && activeJob == nil && storageFault == nil && recoveredPIDs.isEmpty }
    var singleGeneratorIdle: Bool { abWorkflowID == nil && generatorResourcesIdle }
    func canUseS41Resources(_ id: UUID) -> Bool { generatorResourcesIdle && (abWorkflowID == nil || abWorkflowID == id) }
    var canStart: Bool { singleGeneratorIdle && !fixtureQueueCandidates.isEmpty }
    var hasAuthorizedFirstContinuations: Bool {
        state.jobs.contains { $0.status.isPending && $0.externalHistory == nil && $0.supersededBy == nil &&
            $0.h3AutomaticWorkflow?.phase == "pixel_qa" && $0.h3AutomaticWorkflow?.automaticContinuationAuthorized == true }
    }
    var queueDispatchEnabled: Bool { !state.queuePaused || state.automaticLaunchesPaused == false && (hasAuthorizedFirstContinuations || ownedActiveTask != nil) }

    init(root: URL, executable: URL, monitoring: Bool = true, locations: ExternalLocations = .defaults, h3Runtime: H3Runtime = .real, modelStatusService: ModelStatusReadService = .shared, modelStatusTimeout: Double = 8) throws {
        self.root = root.standardizedFileURL
        self.executable = executable
        self.locations = locations
        self.h3Runtime = h3Runtime
        self.statusMonitoringAllowed = monitoring
        self.startupLog = StartupPhaseLog(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard self.root.resolvingSymlinksInPath() == self.root else { throw StudioError.invalid("工作区不能是符号链接。") }
        let fd = open(root.appendingPathComponent(".queue-lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw StudioError.invalid("镜生 H3 已在运行。请打开已有窗口，避免启动第二个队列。")
        }
        lockFD = fd
        let stateURL = root.appendingPathComponent("state.json")
        var recoveredNotice: String?
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do { state = try Self.decodeState(Data(contentsOf: stateURL)) }
            catch {
                let backup = root.appendingPathComponent("state.backup.json")
                if let data = try? Data(contentsOf: backup), let saved = try? Self.decodeState(data) {
                    state = saved; recoveredNotice = "状态文件损坏，已从最近一次有效备份恢复；队列保持暂停。"
                    let damaged = root.appendingPathComponent("state-damaged-\(Int(Date().timeIntervalSince1970)).json")
                    try FileManager.default.copyItem(at: stateURL, to: damaged)
                } else {
                    flock(fd, LOCK_UN); close(fd); lockFD = -1
                    throw StudioError.invalid("状态文件和备份均无法读取。已保留原文件，请修复后再启动。")
                }
            }
        } else { state = WorkspaceState() }
        telemetry = TelemetryMonitor(root: root)
        readiness = ModelReadinessMonitor(root: URL(fileURLWithPath: locations.modelStatusRoot, isDirectory: true), service: modelStatusService, timeout: modelStatusTimeout, log: startupLog)
        state.queuePaused = true // Every launch requires an explicit queue start.
        state.automaticLaunchesPaused = true // Restore inputs and receipts without silently restarting a GPU worker.
        for index in state.jobs.indices where state.jobs[index].h3AutomaticWorkflow?.status == "running" {
            state.jobs[index].h3AutomaticWorkflow?.status = "interrupted";state.jobs[index].h3AutomaticWorkflow?.endedAt = Date()
            if state.jobs[index].status.isPending {
                state.jobs[index].status = .interrupted;state.jobs[index].stage = "自动生成流程中断 · 记录与产物保留"
                state.jobs[index].error = "上次在启动阶段中断；未重复投递，现有记录与产物保留。"
            }
        }
        for index in state.jobs.indices where state.jobs[index].h3InputPreparation?.status == "running" {
            state.jobs[index].h3InputPreparation?.status = "interrupted";state.jobs[index].h3InputPreparation?.endedAt = Date()
            state.jobs[index].h3InputPreparation?.error = "App 在图片处理期间中断；已写出的图片与指纹保留，未进入 GPU。"
            state.jobs[index].status = .interrupted;state.jobs[index].stage = "图片预处理中断 · 未进入 GPU";state.jobs[index].progress = nil
            state.jobs[index].error = state.jobs[index].h3InputPreparation?.error
            recoveredNotice = "图片预处理上次中断；记录与图片保留，未自动生成视频。"
        }
        for index in state.jobs.indices where state.jobs[index].status.isActive && state.jobs[index].externalHistory == nil {
            if let pid = state.jobs[index].workerPID, kill(pid, 0) == 0,
               state.jobs[index].engine == .fixture || state.jobs[index].workerIdentity?.stillSameProcess == true {
                recoveredPIDs.append(pid)
                if state.jobs[index].engine == .h3, let identity = state.jobs[index].workerIdentity { recoveredH3Identities[pid] = identity }
            }
            state.jobs[index].status = .interrupted
            state.jobs[index].stage = state.jobs[index].engine == .h3 ? "单镜运行中断 · 需新的已授权任务" : "运行中断，等待手动重试"
            state.jobs[index].endedAt = Date()
            state.jobs[index].workerPID = nil
            state.jobs[index].error = "应用上次运行中断。候选文件已保留；不会自动恢复旧队列。"
            if !state.jobs[index].attempts.isEmpty {
                let last = state.jobs[index].attempts.count - 1
                state.jobs[index].attempts[last].status = .interrupted
                state.jobs[index].attempts[last].endedAt = Date()
            }
            recoveredNotice = "发现中断任务，已保留记录与候选。H3 需新的已授权单镜；合成任务可手动重试。"
        }
        for index in state.jobs.indices where state.jobs[index].engine == .h3 && state.jobs[index].status.isPending {
            if let binding = state.jobs[index].h3Binding, FileManager.default.fileExists(atPath: self.root.appendingPathComponent("h3-dispatch/\(binding.jobSHA256).json").path) {
                state.jobs[index].status = .interrupted; state.jobs[index].stage = "已有单次投递记录 · 不会再次提交"
                state.jobs[index].error = "投递边界发生中断。请查看原候选与日志，并绑定新的已授权单镜。"
            }
        }
        for index in state.jobs.indices where state.jobs[index].status == .interrupted {
            state.jobs[index].executionActivity?.finish(.interrupted,stage:state.jobs[index].stage,at:state.jobs[index].endedAt ?? Date())
        }
        notice = recoveredNotice
        selectedID = state.jobs.first?.id
        let lease = try JSONEncoder().encode(sessionID)
        try lease.write(to: root.appendingPathComponent("owner.json"), options: .atomic)
        persist()
        telemetry.ownedPIDs = { [weak self] in
            guard let self else { return [] }
            let workerPID = self.activeJob?.engine == .h3 ? self.activeJob?.workerIdentity.flatMap { $0.stillSameProcess ? $0.pid : nil } : self.activeJob?.workerPID
            return Array(Set([workerPID, self.childPID].compactMap { $0 } + self.h3OwnedProcesses.filter(\.stillSameProcess).map(\.pid)))
        }
        telemetry.onSample = { [weak self] sample in self?.record(sample) }
        telemetry.onCriticalPressure = { [weak self] in
            self?.pauseQueue()
            self?.notice = "收到严重内存压力事件，已暂停后续队列。当前任务保留，未自动提高并发。"
        }
        telemetry.configure(enabled: monitoring && state.monitoring, interval: state.samplingInterval)
        // External status reads begin only after the delegate has created and
        // presented the workbench. Initializing this store never waits for them.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.heartbeatTick()
            }
        }
    }
    func heartbeatTick(isAlive: ((Int32) -> Bool)? = nil) {
        let next = recoveredPIDs.filter { pid in
            if let isAlive { return isAlive(pid) }
            if let identity = recoveredH3Identities[pid] { return identity.stillSameProcess }
            return kill(pid,0) == 0
        }
        if next != recoveredPIDs { recoveredPIDs = next }
        let visible = backgroundReadVisible()
        if displayedActiveJob != nil || visible || backgroundReadWasVisible != visible { objectWillChange.send() }
        backgroundReadWasVisible = visible
    }
    private static func decodeState(_ data: Data) throws -> WorkspaceState {
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        guard decoded.version == 1, decoded.jobs.count <= 2000 else { throw StudioError.invalid("状态版本或大小无效。") }
        return decoded
    }
    deinit {
        heartbeat?.invalidate()
        historyTimer?.invalidate()
        firstReviewTimer?.invalidate()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }

    func persist() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let file = root.appendingPathComponent("state.json")
            if let previous = try? Data(contentsOf: file), (try? Self.decodeState(previous)) != nil {
                try previous.write(to: root.appendingPathComponent("state.backup.json"), options: .atomic)
            }
            try data.write(to: file, options: .atomic)
        } catch {
            storageFault = "任务状态无法保存：\(error.localizedDescription)"
            state.queuePaused = true
        }
    }

    func add(_ job: ShotJob) {
        guard state.jobs.count < 2000 else { notice = "工作区已达到 2000 条记录上限。"; return }
        state.jobs.append(job); selectedID = job.id; persist()
    }
    func seedFixtures() {
        guard state.jobs.isEmpty else { return }
        var first = ShotJob.fixture(shot: 2, title: "日月轨迹 · 进度验证")
        first.reference = locations.originalProject + "/assets/wanshenji/codex-keyframes/shot-02-dual-arc-predawn-waypoint-v1.png"
        var second = ShotJob.fixture(shot: 38, title: "山河群像 · 候选验证")
        second.reference = locations.originalProject + "/assets/wanshenji/codex-v5-all/shot-38-heroes-landscape.png"
        add(first); add(second); selectedID = first.id
        notice = "这两条是明确标注的 CPU 合成验证。真实 H3 使用已授权单镜任务，开始后自动执行。"
    }
    @discardableResult func importH3Job(_ url: URL) throws -> UUID {
        let (binding, nativeJob) = try H3Binding.load(url, runtime: h3Runtime)
        guard binding.appTaskID == nil else { throw StudioError.invalid("App 创建的镜头由提案入口登记，不能作为外部 job 重投。") }
        if let index = state.jobs.firstIndex(where: { $0.h3Binding?.jobSHA256 == binding.jobSHA256 || $0.h3Binding?.nativeJobID == binding.nativeJobID }) {
            if state.jobs[index].h3Binding?.jobSHA256 == binding.jobSHA256 && state.jobs[index].status.isPending && state.jobs[index].attempts.isEmpty && !FileManager.default.fileExists(atPath: root.appendingPathComponent("h3-dispatch/\(binding.jobSHA256).json").path) {
                state.jobs[index].h3Binding = binding; state.jobs[index].error = nil; persist()
            }
            selectedID = state.jobs[index].id; notice = "该单镜已在队列中，未重复添加。"; return state.jobs[index].id
        }
        guard state.jobs.count < 2000 else { throw StudioError.invalid("工作区已达到 2000 条记录上限。") }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("h3-dispatch/\(binding.jobSHA256).json").path) else { throw StudioError.invalid("该单镜已有投递记录，请绑定新的已授权任务。") }
        var job = ShotJob(shot: nativeJob.shot_number, segment: nativeJob.segment_id, title: String(format:"S%02d",nativeJob.shot_number) + (h3Runtime.mode == .mock ? " · CPU 模拟单镜协议" : " · 核准原生单镜"),
            prompt: "冻结提示词 SHA-256：" + nativeJob.prompt_sha256, reference: nativeJob.source_image,
            requestedDuration: Double(nativeJob.profile.frames) / Double(nativeJob.profile.fps), engine: .h3, status: .blocked)
        job.h3Binding = binding; job.stage = binding.executionAuthorized ? "单镜已绑定 · 就绪可生成" : "单镜已绑定 · 本次生成尚未授权"
        job.parameters = GenerationParameters(width: h3Runtime.mode == .mock ? 384 : 768, height: h3Runtime.mode == .mock ? 224 : 448,
            frames: h3Runtime.mode == .mock ? 48 : nativeJob.profile.frames, steps: nativeJob.profile.steps, fps: Double(nativeJob.profile.fps), model: h3Runtime.mode == .mock ? "CPU mock · H3 协议验证" : "MiniMax H3 FL2VA 8-bit / Turbo LoRA v4", verified: false)
        add(job); state.queuePaused = true; persist(); return job.id
    }
    func canRunH3(_ id: UUID) -> Bool {
        guard let job = state.jobs.first(where: { $0.id == id }), let binding = job.h3Binding else { return false }
        return (binding.appTaskID == nil ? singleGeneratorIdle : canUseS41Resources(id)) && nativeReadiness(job).ready
    }
    func startH3(_ id: UUID, approval: H3LaunchApproval,firstLaunchCheck: H3FirstLaunchCheck? = nil) {
        guard canRunH3(id), let index = state.jobs.firstIndex(where: { $0.id == id }), let binding = state.jobs[index].h3Binding else { return }
        var reserved = false
        do {
            switch approval {
            case .userConfirmed(let hash): guard hash == binding.jobSHA256 else { throw StudioError.invalid("确认的任务绑定已变化，未启动。") }
            case .mockForTests(let hash): guard binding.runtime.mode == .mock && hash == binding.jobSHA256 else { throw StudioError.invalid("测试确认不能启动真实 H3。") }
            }
            if binding.appFirstTask != nil {
                guard let firstLaunchCheck,firstLaunchCheck.binding == binding,
                      (0...3).contains(Date().timeIntervalSince(firstLaunchCheck.completedAt)) else { throw StudioError.invalid("首帧任务必须先在后台完成冻结检查。") }
            } else { _ = try binding.revalidate() }
            try binding.requireExecutionAuthorization()
            if let ab = binding.appABTask { guard ab.appJobID == id,ab.appWorkspace == root.path else { throw StudioError.invalid("S41 绑定不属于这条 App 任务与工作区。") } }
            if let first = binding.appFirstTask { guard first.appJobID == id,first.appWorkspace == root.path else { throw StudioError.invalid("首帧绑定不属于当前 App 任务与工作区。") } }
            guard let owner = ProcessIdentity.capture(getpid()), telemetry.pressure != "严重" else { throw StudioError.invalid("无法确认进程身份或内存压力严重，未启动单镜。") }
            let capacity = try URL(fileURLWithPath: binding.runtime.workDirectory).resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard Int64(capacity) >= binding.minimumFreeBytes else { throw StudioError.invalid("磁盘余量不足单镜核准储备，未启动。") }
            let ledgerDirectory = root.appendingPathComponent("h3-dispatch", isDirectory: true)
            try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
            let receiptURL = ledgerDirectory.appendingPathComponent(binding.jobSHA256 + ".json")
            var receipt = H3DispatchReceipt(jobSHA256: binding.jobSHA256, nativeJobID: binding.nativeJobID, appJobID: id, sessionID: sessionID)
            if let ab = binding.appABTask {
                receipt.proposalID = ab.configuration.proposalID;receipt.nativeFrames = binding.profile.frames;receipt.editorialFrames = ab.configuration.editorialFrames
                receipt.inputSHA256s = ["A_original":ab.configuration.first.originalSHA256!,"B_original":ab.configuration.last.originalSHA256!,"A_normalized":ab.configuration.first.normalizedSHA256!,"B_normalized":ab.configuration.last.normalizedSHA256!,"prompt":ab.configuration.promptSHA256!,"effective_configuration":ab.configuration.sourceSHA256]
            }
            if let first = binding.appFirstTask,let input = first.proposal.input {
                receipt.proposalID = first.proposal.proposalID;receipt.nativeFrames = binding.profile.frames;receipt.editorialFrames = first.proposal.targetFrames
                receipt.inputSHA256s = ["source_media":first.proposal.sourceMediaSHA256,"A_original":input.originalSHA256,
                    "A_normalized":input.normalizedSHA256,"prompt":first.proposal.promptSHA256,"effective_configuration":first.configurationSHA256]
            }
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .withoutOverwriting)
            reserved = true
            // Reservation is durable before process creation. Any failure from here
            // requires a different authorized job, including a launch-boundary crash.
            let number = (state.jobs[index].attempts.map(\.number).max() ?? 0) + 1
            let directory = root.appendingPathComponent("candidates/\(id.uuidString)/attempt-\(number)", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw StudioError.invalid("应用尝试目录已存在，拒绝覆盖。") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let request = H3WorkerRequest(appJobID: id, sessionID: sessionID, owner: owner, workspace: root.path, attemptDirectory: directory.path, binding: binding, ffmpeg: locations.ffmpeg)
            let requestURL = directory.appendingPathComponent("h3-request.json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .withoutOverwriting)
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent("engine.log").path, contents: nil) else { throw StudioError.invalid("无法创建单镜日志。") }
            logHandle = try FileHandle(forWritingTo: directory.appendingPathComponent("engine.log"))
            let now = Date(); state.jobs[index].status = .running; state.jobs[index].stage = "单镜启动 · 不自动运行后续镜头"
            state.jobs[index].startedAt = now; state.jobs[index].endedAt = nil; state.jobs[index].error = nil; state.jobs[index].progress = nil; state.jobs[index].h3Outcome = nil
            if binding.appTaskID != nil { state.jobs[index].logTail.append("App 已持久领取本次 \(state.jobs[index].shortID)，开始自有原生执行；全部输入预处理记录持续保留。") }
            else { state.jobs[index].logTail = [] }
            state.jobs[index].attempts.append(Attempt(number: number, startedAt: now, status: .running, directory: directory.path))
            if state.jobs[index].executionActivity == nil { state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:now) }
            else { state.jobs[index].executionActivity?.milestone(state.jobs[index].stage,at:now,phase:.starting) }
            state.jobs[index].attempts[state.jobs[index].attempts.count - 1].parameters = state.jobs[index].parameters
            state.queuePaused = true; pendingOutput = nil; h3OwnedProcesses = []; childPID = nil
            let next = ProcessRunner(); runner = next; persist()
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            try next.start(executable: executable, arguments: ["--h3-worker", requestURL.path], directory: URL(fileURLWithPath: binding.runtime.workDirectory), onLine: { [weak self] line, stderr in
                self?.consume(line, stderr: stderr, jobID: id, attemptNumber: number)
            }, onExit: { [weak self] code in self?.finish(jobID: id, attemptNumber: number, code: code) })
            state.jobs[index].workerPID = next.process.processIdentifier; state.jobs[index].workerIdentity = ProcessIdentity.capture(next.process.processIdentifier)
            receipt.supervisor = state.jobs[index].workerIdentity; try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            launchCount += 1; persist()
            telemetry.configure(enabled: telemetry.enabled, interval: max(10, state.samplingInterval))
        } catch {
            // If a process has already started, let the supervisor stop its own
            // descendants and let the exit callback finalize the attempt.
            if runner?.process.isRunning == true { state.jobs[index].error = error.localizedDescription; cancel(id) }
            else if reserved { runner = nil; try? logHandle?.close(); logHandle = nil; fail(index, message: error.localizedDescription) }
            else { state.jobs[index].error = error.localizedDescription; state.jobs[index].stage = "单镜未启动 · 请核对绑定与条件"; notice = error.localizedDescription; persist() }
        }
    }
    @discardableResult func importManifest(_ url: URL) throws -> Int {
        guard !url.standardizedFileURL.pathComponents.contains("sessions"), !url.resolvingSymlinksInPath().pathComponents.contains("sessions") else {
            throw StudioError.invalid("不读取 sessions 目录。")
        }
        let incoming = try ManifestImporter.parse(Data(contentsOf: url), url: url)
        var keys = Set(state.jobs.compactMap(\.importKey))
        let unique = incoming.filter { job in
            guard let key = job.importKey, !keys.contains(key) else { return false }
            keys.insert(key); return true
        }
        guard state.jobs.count + unique.count <= 2000 else { throw StudioError.invalid("导入后将超过工作区记录上限。") }
        state.jobs.append(contentsOf: unique)
        if let first = unique.first { selectedID = first.id }
        notice = "已导入 \(unique.count) 条镜头，跳过 \(incoming.count - unique.count) 条重复记录。H3 镜头尚未绑定核准单镜，未启动。"
        persist(); return unique.count
    }

    func startQueue() {
        guard canStart else { return }
        let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let capacity, capacity < 256 * 1024 * 1024 { notice = "候选目录所在磁盘不足 256 MB，队列未启动。"; return }
        if telemetry.pressure == "严重" { notice = "系统内存压力严重，稍后再启动队列。"; return }
        state.queuePaused = false;state.automaticLaunchesPaused = false;persist();launchNext()
    }
    func pauseQueue() { state.queuePaused = true;state.automaticLaunchesPaused = true;persist() }
    func resumeAuthorizedFirstQueue() async {
        guard singleGeneratorIdle,hasAuthorizedFirstContinuations else { return }
        state.automaticLaunchesPaused = false;persist()
        guard storageFault == nil else { return }
        await checkFirstPixelReviews()
    }
    func canMovePending(_ id: UUID, offset: Int) -> Bool {
        let pending = state.jobs.filter { $0.status.isPending }
        guard abs(offset) == 1, let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        return pending.indices.contains(index + offset)
    }
    @discardableResult func movePending(_ id: UUID, offset: Int) -> Bool {
        guard canMovePending(id, offset: offset) else { return false }
        let indices = state.jobs.indices.filter { state.jobs[$0].status.isPending && state.jobs[$0].externalHistory == nil }
        guard let position = indices.firstIndex(where: { state.jobs[$0].id == id }) else { return false }
        state.jobs.swapAt(indices[position], indices[position + offset])
        persist(); return true
    }
    @discardableResult func movePending(_ id: UUID, before targetID: UUID) -> Bool {
        guard id != targetID else { return false }
        let indices = state.jobs.indices.filter { state.jobs[$0].status.isPending && state.jobs[$0].externalHistory == nil }
        var pending = indices.map { state.jobs[$0] }
        let previous = pending.map(\.id)
        guard let source = pending.firstIndex(where: { $0.id == id }), pending.contains(where: { $0.id == targetID }) else { return false }
        let moved = pending.remove(at: source)
        guard let target = pending.firstIndex(where: { $0.id == targetID }) else { return false }
        pending.insert(moved, at: target)
        guard previous != pending.map(\.id) else { return false }
        for (index, job) in zip(indices, pending) { state.jobs[index] = job }
        persist(); return true
    }
    private func launchNext() {
        guard singleGeneratorIdle, !state.queuePaused, let next = fixtureQueueCandidates.first,
              let index = state.jobs.firstIndex(where: { $0.id == next.id }) else { return }
        let jobID = state.jobs[index].id
        do {
            let attemptNumber = (state.jobs[index].attempts.map(\.number).max() ?? 0) + 1
            let parent = root.appendingPathComponent("candidates/\(jobID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let directory = parent.appendingPathComponent("attempt-\(attemptNumber)", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw StudioError.invalid("候选尝试目录已存在，拒绝覆盖。") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let now = Date()
            state.jobs[index].status = .running; state.jobs[index].stage = "准备合成验证"
            state.jobs[index].startedAt = now; state.jobs[index].endedAt = nil
            state.jobs[index].error = nil; state.jobs[index].progress = nil
            state.jobs[index].logTail = []
            state.jobs[index].attempts.append(Attempt(number: attemptNumber, startedAt: now, status: .running, directory: directory.path))
            state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:now)
            state.jobs[index].attempts[state.jobs[index].attempts.count - 1].parameters = state.jobs[index].parameters
            let request = WorkerRequest(jobID: jobID, sessionID: sessionID, ownerPID: getpid(), workspace: root.path,
                outputDirectory: directory.path, fail: state.jobs[index].fixtureFailure, delay: state.jobs[index].fixtureDelay, ffmpeg: locations.ffmpeg)
            let requestURL = directory.appendingPathComponent("request.json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .withoutOverwriting)
            let log = directory.appendingPathComponent("engine.log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw StudioError.invalid("无法创建任务日志。") }
            logHandle = try FileHandle(forWritingTo: log)
            pendingOutput = nil; childPID = nil
            let next = ProcessRunner(); runner = next
            persist()
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            try next.start(executable: executable, request: requestURL, onLine: { [weak self] line, stderr in
                self?.consume(line, stderr: stderr, jobID: jobID, attemptNumber: attemptNumber)
            }, onExit: { [weak self] code in self?.finish(jobID: jobID, attemptNumber: attemptNumber, code: code) })
            state.jobs[index].workerPID = next.process.processIdentifier
            launchCount += 1
            persist()
            if telemetry.enabled { telemetry.sampleNow() }
        } catch {
            runner = nil; try? logHandle?.close(); logHandle = nil
            fail(index, message: error.localizedDescription)
        }
    }
    func consume(_ line: String, stderr: Bool, jobID: UUID, attemptNumber: Int) {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }),
              state.jobs[index].attempts.last?.number == attemptNumber else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "\(timestamp) \(stderr ? "stderr" : "stdout") \(line)"
        do { try logHandle?.write(contentsOf: Data((logLine + "\n").utf8)) }
        catch { storageFault = "任务日志无法保存：\(error.localizedDescription)"; state.queuePaused = true }
        state.jobs[index].logTail.append(logLine)
        if state.jobs[index].logTail.count > 160 { state.jobs[index].logTail.removeFirst() }
        guard !stderr, let event = try? JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) else { return }
        if event.type == "progress" {
            guard let total = event.total,let completed = event.completed,(1...1_000_000).contains(total),(0...total).contains(completed) else { return }
        }
        if state.jobs[index].status.isActive && state.jobs[index].status != .cancelling {
            if state.jobs[index].executionActivity == nil { state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:Date()) }
            var evidence = event
            if event.type == "owned" { evidence.ownedProcesses = (event.ownedProcesses ?? []).filter(\.stillSameProcess) }
            state.jobs[index].executionActivity?.observe(evidence,at:Date())
        }
        if state.jobs[index].status != .cancelling, let stage = event.stage, stage != state.jobs[index].stage {
            state.jobs[index].stage = stage; state.jobs[index].progress = nil
        }
        switch event.type {
        case "native_started":
            if state.jobs[index].h3ABConfiguration != nil || state.jobs[index].h3FirstProposal != nil { state.jobs[index].h3GenerationStartedAt = Date() }
        case "validation_started":
            if state.jobs[index].h3ABConfiguration != nil || state.jobs[index].h3FirstProposal != nil { let now = Date();state.jobs[index].h3GenerationEndedAt = now;state.jobs[index].h3ValidationStartedAt = now }
        case "progress":
            guard state.jobs[index].status != .cancelling else { break }
            if let total = event.total, let completed = event.completed, total > 0, total <= 1000000,
               completed >= 0, completed <= total {
                if let previous = state.jobs[index].progress, previous.total == total, completed < previous.completed { break }
                state.jobs[index].progress = StageProgress(completed: completed, total: total, unit: event.unit ?? "步")
            }
        case "output":
            if let path = event.path, let attempt = state.jobs[index].attempts.last {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                if url.path.hasPrefix(attempt.directory + "/"), url.resolvingSymlinksInPath() == url,
                   FileManager.default.fileExists(atPath: url.path) {
                    pendingOutput = url.path
                    state.jobs[index].candidate = url.path
                    state.jobs[index].attempts[state.jobs[index].attempts.count - 1].candidate = url.path
                } else { state.jobs[index].error = "引擎返回了不属于当前候选目录的输出。" }
            }
        case "child": childPID = event.childPID
        case "owned":
            if state.jobs[index].engine == .h3 { h3OwnedProcesses = (event.ownedProcesses ?? []).filter(\.stillSameProcess) }
        case "technical_pass", "partial_output":
            if state.jobs[index].engine == .h3, let binding = state.jobs[index].h3Binding, event.path == binding.clipPath,
               let path = event.path, (try? H3Files.inside(path, binding.outputDirectory)) != nil, FileManager.default.fileExists(atPath: path) {
                state.jobs[index].candidate = path; state.jobs[index].attempts[state.jobs[index].attempts.count - 1].candidate = path
                if event.type == "technical_pass", let report = event.reportPath, report == binding.outputDirectory + "/technical-validation.json", event.simulated == (binding.runtime.mode == .mock) {
                    pendingOutput = path; state.jobs[index].h3Outcome = H3Outcome(technicalPass: true, visualReview: "not_automatically_evaluated", reportPath: report, simulated: event.simulated ?? false)
                    state.jobs[index].parameters.verified = true
                    state.jobs[index].attempts[state.jobs[index].attempts.count - 1].parameters = state.jobs[index].parameters
                }
            } else { state.jobs[index].error = "单镜返回了不属于已绑定候选目录的输出。" }
        case "error": state.jobs[index].error = event.message ?? "生成器错误"
        default: break
        }
        state.jobs[index].updatedAt = Date(); persist()
    }
    private func finish(jobID: UUID, attemptNumber: Int, code: Int32) {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }), state.jobs[index].attempts.last?.number == attemptNumber else { return }
        if telemetry.enabled { telemetry.sampleNow() }
        let cancelled = state.jobs[index].status == .cancelling
        let complete = code == 0 && pendingOutput != nil && state.jobs[index].error == nil && (state.jobs[index].engine == .fixture || state.jobs[index].h3Outcome?.technicalPass == true)
        let status: JobStatus = cancelled ? .cancelled : complete ? .completed : .failed
        state.jobs[index].status = status
        state.jobs[index].stage = status == .completed ? "候选已生成" : status == .cancelled ? "已取消 · 保留候选文件" : "任务失败 · 队列暂停"
        if status == .completed && state.jobs[index].engine == .h3 { state.jobs[index].stage = state.jobs[index].h3Outcome?.simulated == true ? "CPU 模拟协议通过 · 非真实 H3" : "自动技术检查通过 · 候选已保存" }
        if state.jobs[index].h3AutomaticWorkflow != nil {
            state.jobs[index].h3AutomaticWorkflow?.status = status.rawValue;state.jobs[index].h3AutomaticWorkflow?.phase = "finished"
            state.jobs[index].h3AutomaticWorkflow?.endedAt = Date();state.jobs[index].h3AutomaticWorkflow?.error = state.jobs[index].error
        }
        state.jobs[index].endedAt = Date(); state.jobs[index].workerPID = nil
        if state.jobs[index].h3GenerationStartedAt != nil && state.jobs[index].h3GenerationEndedAt == nil { state.jobs[index].h3GenerationEndedAt = state.jobs[index].endedAt }
        if state.jobs[index].h3ValidationStartedAt != nil { state.jobs[index].h3ValidationEndedAt = state.jobs[index].endedAt }
        state.jobs[index].progress = nil
        if status == .failed && state.jobs[index].error == nil { state.jobs[index].error = "生成器退出代码 \(code)。没有确认完整候选输出。" }
        state.jobs[index].executionActivity?.finish(status,stage:state.jobs[index].stage,at:state.jobs[index].endedAt!)
        let last = state.jobs[index].attempts.count - 1
        state.jobs[index].attempts[last].status = status; state.jobs[index].attempts[last].endedAt = Date()
        state.jobs[index].attempts[last].error = state.jobs[index].error
        if let metrics = try? JSONEncoder().encode(state.jobs[index].attempts[last]) {
            try? metrics.write(to: URL(fileURLWithPath: state.jobs[index].attempts[last].directory).appendingPathComponent("attempt-metrics.json"), options: .atomic)
        }
        if status != .completed { state.queuePaused = true;state.automaticLaunchesPaused = true }
        try? logHandle?.close(); logHandle = nil
        runner = nil; childPID = nil; pendingOutput = nil; h3OwnedProcesses = []
        telemetry.configure(enabled: telemetry.enabled, interval: state.samplingInterval)
        persist(); launchNext()
    }
    private func fail(_ index: Int, message: String) {
        state.jobs[index].status = .failed; state.jobs[index].error = message; state.jobs[index].stage = "任务失败 · 队列暂停"
        state.jobs[index].endedAt = Date(); state.jobs[index].workerPID = nil; state.queuePaused = true;state.automaticLaunchesPaused = true
        state.jobs[index].executionActivity?.finish(.failed,stage:state.jobs[index].stage,at:state.jobs[index].endedAt!)
        if !state.jobs[index].attempts.isEmpty {
            let last = state.jobs[index].attempts.count - 1
            state.jobs[index].attempts[last].status = .failed
            state.jobs[index].attempts[last].endedAt = Date(); state.jobs[index].attempts[last].error = message
        }
        persist()
    }
    func cancel(_ id: UUID,source: String = "application-or-test") {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].externalHistory == nil else { return }
        if actionRevisionID == id {
            actionRevisionControl?.cancel();notice = "已取消动作修订；原失败记录、提示词与检查回执保留。";return
        }
        if abPreparationID == id {
            abPreparationControl?.cancel()
            state.jobs[index].h3InputPreparation?.status = "cancelled"
            if state.jobs[index].h3InputPreparation?.cancellationRequestedAt == nil { state.jobs[index].h3InputPreparation?.cancellationRequestedAt = Date() }
        }
        if state.jobs[index].status == .running {
            guard activeJob?.id == id, runner != nil else { return }
            state.jobs[index].status = .cancelling; state.jobs[index].stage = "正在取消 · 保留输出"
            state.jobs[index].executionActivity?.milestone(state.jobs[index].stage,at:Date(),phase:.cancelling)
            state.jobs[index].h3AutomaticWorkflow?.status = "cancelling"
            state.jobs[index].updatedAt = Date()
            state.jobs[index].cancellationSource = source
            state.jobs[index].logTail.append("取消请求来源：" + source)
            state.queuePaused = true;state.automaticLaunchesPaused = true;persist();runner?.cancel()
        } else if [.queued, .blocked].contains(state.jobs[index].status) {
            state.jobs[index].status = .cancelled
            state.jobs[index].h3AutomaticWorkflow?.status = "cancelled";state.jobs[index].h3AutomaticWorkflow?.endedAt = Date()
            if state.jobs[index].h3InputPreparation?.automaticValidationStatus == "running" {
                state.jobs[index].h3InputPreparation?.automaticValidationStatus = "cancelled"
                state.jobs[index].h3InputPreparation?.automaticValidationEndedAt = Date()
            }
            state.jobs[index].stage = abPreparationID == id ? "已取消图片预处理 · 未进入 GPU" : "已取消 · 未启动；模型下载不受影响"
            state.jobs[index].endedAt = Date(); state.jobs[index].updatedAt = Date()
            state.jobs[index].executionActivity?.finish(.cancelled,stage:state.jobs[index].stage,at:state.jobs[index].endedAt!)
            state.jobs[index].cancellationSource = source
            state.jobs[index].logTail.append("取消未启动任务；请求来源：" + source)
            persist()
        }
    }
    func retry(_ id: UUID) {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].status.canRetry else { return }
        guard state.jobs[index].engine == .fixture else { notice = "H3 单镜不重投已领取的任务。请导入新的已授权单镜；原候选与日志保留。"; return }
        state.jobs[index].status = state.jobs[index].engine == .fixture ? .queued : .blocked
        state.jobs[index].stage = state.jobs[index].engine == .fixture ? "等待手动开始" : "等待核准的 H3 引擎契约"
        state.jobs[index].error = nil; state.jobs[index].progress = nil; state.jobs[index].workerPID = nil
        state.jobs[index].fixtureFailure = false
        state.jobs[index].updatedAt = Date()
        state.queuePaused = true; persist()
    }
    private func record(_ sample: ResourceSample) {
        guard let index = state.jobs.firstIndex(where: { $0.status.isActive && $0.externalHistory == nil }), !state.jobs[index].attempts.isEmpty else { return }
        let last = state.jobs[index].attempts.count - 1
        state.jobs[index].attempts[last].peaks.include(sample, gpuSince: state.jobs[index].attempts[last].startedAt)
        if let attempt = state.jobs[index].attempts.last {
            if let data = try? JSONEncoder().encode(telemetry.samples.filter { $0.timestamp >= attempt.startedAt }) {
                try? data.write(to: URL(fileURLWithPath: attempt.directory).appendingPathComponent("resources.json"), options: .atomic)
            }
        }
        persist()
    }
    func configureMonitoring(enabled: Bool, interval: Double) {
        state.monitoring = enabled; state.samplingInterval = max(2, interval)
        persist(); telemetry.configure(enabled: enabled, interval: activeJob?.engine == .h3 ? max(10, interval) : interval)
    }
    func setTheme(_ theme: String) { state.theme = theme; persist() }
    func startBackgroundStatus() { if statusMonitoringAllowed { readiness.start() } }
    func setOrbOrigin(x: Double, y: Double) { state.orbX = x; state.orbY = y; persist() }
    func shutdown() {
        shuttingDown = true
        historyTimer?.invalidate(); historyTimer = nil
        firstReviewTimer?.invalidate(); firstReviewTimer = nil
        startupLog.record(.shutdownRequested)
        pauseQueue()
        actionRevisionControl?.cancel()
        if let id = abPreparationID { cancel(id,source:"application shutdown during input preparation") }
        if let id = abWorkflowID { cancel(id,source:"application shutdown during automatic workflow") }
        if let active = activeJob { cancel(active.id,source:"application shutdown") }
        telemetry.configure(enabled: false, interval: state.samplingInterval)
        readiness.stop()
    }
    func exportRecords(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state.jobs).write(to: url, options: .atomic)
    }
}
