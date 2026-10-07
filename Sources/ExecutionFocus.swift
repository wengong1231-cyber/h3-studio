import Foundation

enum ExecutionFocusMode: String { case idle, generation, preparation, observed, cancelling }
struct ExecutionCurrentFocus {
    var job: ShotJob
    var mode: ExecutionFocusMode
    var activity: ActivityPresentation
}
struct ExecutionNextFocus {
    var job: ShotJob
    var readiness: QueueReadiness
    var resourceWait: String?
    var queuePaused: Bool
    var orderLabel: String
    var stateLabel: String {
        if queuePaused { return "队列已暂停 · 下一项已就绪" }
        if resourceWait != nil { return "下一项已就绪 · 等待资源释放" }
        return readiness.operation == .fixture ? "下一项可执行" : readiness.operation == .inputReview ? "下一项可核对并接续" : "下一项可准备"
    }
    var detail: String { resourceWait ?? readiness.reason }
}
struct ExecutionFocusProjection {
    var current: ExecutionCurrentFocus?
    var next: ExecutionNextFocus?
    var waitingJob: ShotJob?
    var waitingReason: String?
    var globalWait: String?
    var conflictingActiveRecords: Int
    var orbCurrent: String { current.map { $0.job.focusTaskLabel + " · " + ($0.mode == .preparation ? "CPU 准备" : $0.mode == .observed ? "外部记录" : $0.mode == .cancelling ? "取消中" : $0.activity.shortState) } ?? "当前无执行任务" }
    var orbNext: String { next.map { "下一项 " + $0.job.focusTaskLabel + ($0.queuePaused ? " · 队列暂停" : "") } ?? "下一项 " + (waitingReason ?? "暂无待执行任务") }
    var orbIdleActivity: ActivityPresentation {
        .init(state:"当前没有执行任务",stage:globalWait ?? waitingReason ?? next?.stateLabel ?? "暂无待执行任务",
            detail:"尚未启动新的生成任务",elapsed:"未启动",lastProgress:"没有新的生成进展",tone:.waiting,symbol:"clock",shortState:"空闲")
    }
}

enum FocusMotionPolicy {
    static func shouldAnimate(mode: ExecutionFocusMode,reduceMotion: Bool,windowVisible: Bool) -> Bool {
        mode == .generation && !reduceMotion && windowVisible
    }
}

extension ShotJob {
    var focusTaskLabel: String { shortID + (h3QueuePlan.map { " · 第\($0.part)/\($0.partCount)段" } ?? " · " + segment) }
}

enum ExecutionFocusProjector {
    static func project(jobs: [ShotJob],ownedWorkflowID: UUID?,preparationID: UUID?,resourceIdle: Bool,
                        globalWait: String?,queuePaused: Bool,now: Date,reviewExists: (UUID) -> Bool,
                        alreadyDispatched: (ShotJob) -> Bool,inputReviewExists: (UUID) -> Bool = { _ in false },
                        automaticLaunchesPaused: Bool = false) -> ExecutionFocusProjection {
        let active = jobs.filter { $0.status.isActive && $0.externalHistory == nil && $0.supersededBy == nil }
        let preparing = jobs.first { $0.supersededBy == nil && $0.status.isPending &&
            ($0.id == ownedWorkflowID || $0.id == preparationID) && $0.h3AutomaticWorkflow?.status != "waiting" }
        let observed = jobs.first { $0.externalHistory?.observing == true }
        let currentJob = active.first ?? preparing ?? observed
        let current = currentJob.map { job in
            ExecutionCurrentFocus(job:job,mode:job.status == .cancelling ? .cancelling : job.externalHistory != nil ? .observed : job.status == .running ? .generation : .preparation,
                activity:ActivityPresenter.job(job,now:now,automaticLaunchesPaused:automaticLaunchesPaused))
        }
        let evaluated = QueueScheduling.evaluatedPending(jobs,excluding:currentJob?.id,preferFixtures:currentJob?.engine == .fixture,
            reviewExists:reviewExists,alreadyDispatched:alreadyDispatched,inputReviewExists:inputReviewExists)
        let firstReady = evaluated.first { $0.readiness.ready }
        let wait = globalWait ?? (resourceIdle ? nil : "等待当前任务释放串行生成资源")
        let next = firstReady.map { candidate in
            let job = candidate.job,readiness = candidate.readiness
            return ExecutionNextFocus(job:job,readiness:readiness,resourceWait:wait,queuePaused:readiness.operation == .fixture ? queuePaused : automaticLaunchesPaused,
                orderLabel:job.h3QueuePlan.map { "镜头优先级 \($0.priority) · 第\($0.part)段" } ?? "按队列顺序")
        }
        let blocked = evaluated.first { !$0.readiness.ready }
        return .init(current:current,next:next,waitingJob:next == nil ? blocked?.job : nil,
            waitingReason:next == nil ? blocked?.readiness.reason : nil,globalWait:globalWait,conflictingActiveRecords:active.count)
    }
}

extension TaskStore {
    func executionFocus(at now: Date = Date()) -> ExecutionFocusProjection {
        let wait: String?
        if shuttingDown { wait = "应用正在结束当前工作" }
        else if storageFault != nil { wait = "工作区无法保存，队列保持暂停" }
        else if !recoveredPIDs.isEmpty { wait = "等待旧自有进程安全退出" }
        else if abConfigurationBusy || backgroundReadVisible(at:now) { wait = "后台正在核对本地记录" }
        else { wait = nil }
        var projection = ExecutionFocusProjector.project(jobs:state.jobs,ownedWorkflowID:abWorkflowID,preparationID:abPreparationID,
            resourceIdle:ownedActiveTask == nil && observedJob == nil && wait == nil,globalWait:wait,queuePaused:state.queuePaused,now:now,
            reviewExists:{ FileManager.default.fileExists(atPath:H3QueueExecution.reviewURL(workspace:self.root,id:$0).path) },
            alreadyDispatched:{ self.alreadyDispatched($0) },
            inputReviewExists:{ FileManager.default.fileExists(atPath:self.firstReviewURL($0).path) },
            automaticLaunchesPaused:state.automaticLaunchesPaused == true)
        if let id = fidelityJobID,let job = state.jobs.first(where:{ $0.id == id }),let record = job.h3FidelityChecks?.last {
            let activity = ActivityPresentation(state:record.kind.title,stage:record.stage,
                detail:"原片与拒绝保留 · 实验不授权续段",elapsed:ActivityPresenter.duration(now.timeIntervalSince(record.startedAt)),elapsedTitle:"对照用时",
                lastProgress:record.progress?.label ?? "等待原生阶段上报",tone:.working,progress:record.progress,symbol:"person.crop.rectangle",shortState:"保真对照")
            projection.current = .init(job:job,mode:record.status == "cancelling" ? .cancelling : .generation,activity:activity)
        }
        return projection
    }
}
