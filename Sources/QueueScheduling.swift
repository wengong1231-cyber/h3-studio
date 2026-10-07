import Foundation

enum QueueOperation: String { case fixture, plannedPreparation, firstPreparation, inputReview, abPreparation, nativeGeneration }

struct QueueReadiness: Equatable {
    var operation: QueueOperation
    var ready: Bool
    var reason: String
    static func waiting(_ operation: QueueOperation,_ reason: String) -> Self { .init(operation:operation,ready:false,reason:reason) }
    static func eligible(_ operation: QueueOperation,_ reason: String) -> Self { .init(operation:operation,ready:true,reason:reason) }
}

struct QueueCandidate {
    var job: ShotJob
    var readiness: QueueReadiness
}

/// One intrinsic readiness policy for the scheduler and its read-only UI. The
/// resource lease is checked separately, so an active worker does not make a
/// ready successor appear to have missing input. No receipt is created here.
enum QueueScheduling {
    static func dependencyBlocker(_ job: ShotJob,jobs: [ShotJob],reviewExists: (UUID) -> Bool,operation: QueueOperation) -> QueueReadiness? {
        guard let plan = job.h3QueuePlan,let request = plan.dependencyRequestID else { return nil }
        guard let prior = jobs.first(where:{ $0.h3QueuePlan?.requestID == request && $0.supersededBy == nil && $0.externalHistory == nil }) else {
            return .waiting(operation,"前段任务关系缺失")
        }
        if prior.h3VideoRejection != nil { return .waiting(operation,"前段候选已拒绝，等待重做") }
        guard prior.status == .completed,prior.h3Outcome?.technicalPass == true else { return .waiting(operation,"等待前段完成与技术检查") }
        guard prior.videoContinuationAuthorized else { return .waiting(operation,"等待前段接受来源与续段授权核对") }
        if let provenance = prior.h3VideoReview?.provenance,provenance.declaresProductAcceptance,
           provenance.successorAppJobID != job.id || provenance.successorRequestID != plan.requestID {
            return .waiting(operation,"前段接受绑定另一版续段，当前重做关系待核对")
        }
        guard reviewExists(prior.id) else { return .waiting(operation,"前段回执文件缺失") }
        return nil
    }
    static func plannedReadiness(_ job: ShotJob,jobs: [ShotJob],reviewExists: (UUID) -> Bool) -> QueueReadiness {
        let operation = QueueOperation.plannedPreparation
        guard job.status.isPending,job.externalHistory == nil,job.supersededBy == nil,
              job.h3Binding == nil,job.attempts.isEmpty,job.h3FirstProposal == nil,let plan = job.h3QueuePlan else {
            return .waiting(operation,"当前记录不能作为新的待准备段")
        }
        if job.requiresNewStaticInput == true && job.h3StaticBinding == nil { return .waiting(operation,"等待绑定新的完整首图") }
        if job.h3StaticBinding?.hasRequiredPhaseAllocation == false { return .waiting(operation,"等待 S05 三阶段边界记录") }
        if plan.dependencyRequestID != nil {
            if let blocked = dependencyBlocker(job,jobs:jobs,reviewExists:reviewExists,operation:operation) { return blocked }
            return .eligible(operation,"前段与回执已就绪，可准备实际端点")
        }
        guard job.h3StaticBinding != nil || plan.sourceMediaPath != nil && plan.sourceGlobalFrameIndex != nil else {
            return .waiting(operation,"实际首图或源帧来源尚未绑定")
        }
        return .eligible(operation,"输入来源已登记，可准备并检查画面")
    }
    static func firstReadiness(_ job: ShotJob) -> QueueReadiness {
        guard job.status.isPending,job.externalHistory == nil,job.supersededBy == nil,job.attempts.isEmpty,
              job.h3Binding == nil,job.h3FirstProposal?.launchAuthorized == true,job.h3AutomaticWorkflow == nil else {
            return .waiting(.firstPreparation,"首图准备条件尚未齐备")
        }
        if job.requiresNewStaticInput == true && job.h3FirstProposal?.isStaticInput != true {
            return .waiting(.firstPreparation,"新修订需要新的完整首图")
        }
        return .eligible(.firstPreparation,"已授权的输入提案，可准备实际首图")
    }
    static func nativeReadiness(_ job: ShotJob,alreadyDispatched: Bool) -> QueueReadiness {
        guard job.status.isPending,job.engine == .h3,job.externalHistory == nil,job.supersededBy == nil,
              let binding = job.h3Binding,binding.executionAuthorized else { return .waiting(.nativeGeneration,"本次原生任务绑定或授权未就绪") }
        guard !alreadyDispatched else { return .waiting(.nativeGeneration,"已有一次投递记录，不会重复启动") }
        return .eligible(.nativeGeneration,"原生任务已绑定，启动前再次核对冻结文件")
    }
    static func readiness(_ job: ShotJob,jobs: [ShotJob],reviewExists: (UUID) -> Bool,alreadyDispatched: (ShotJob) -> Bool,
                          inputReviewExists: (UUID) -> Bool = { _ in false }) -> QueueReadiness {
        if job.engine == .fixture {
            return job.status == .queued && job.externalHistory == nil && job.supersededBy == nil
                ? .eligible(.fixture,"串行 CPU 合成验证") : .waiting(.fixture,"当前合成任务不在待执行队列")
        }
        if let proposal = job.h3FirstProposal {
            if job.h3AutomaticWorkflow?.phase == "pixel_qa" {
                guard job.status.isPending,job.externalHistory == nil,job.supersededBy == nil,proposal.input != nil,
                      proposal.launchAuthorized,job.h3AutomaticWorkflow?.automaticContinuationAuthorized == true,
                      !alreadyDispatched(job) else { return .waiting(.inputReview,"本次输入检查不能重复接续") }
                if let blocked = dependencyBlocker(job,jobs:jobs,reviewExists:reviewExists,operation:.inputReview) { return blocked }
                if inputReviewExists(job.id) { return .eligible(.inputReview,"助手图审回执已到达；核对实际输入指纹后接续") }
                return .waiting(.inputReview,"助手正在核对实际图片与提示词；尚未进入生成")
            }
            if job.h3AutomaticWorkflow == nil && job.h3Binding == nil {
                return dependencyBlocker(job,jobs:jobs,reviewExists:reviewExists,operation:.firstPreparation) ?? firstReadiness(job)
            }
            if !proposal.reviewReady { return .waiting(.inputReview,"实际图片与提示词检查尚未通过") }
        }
        if job.h3Binding != nil {
            return dependencyBlocker(job,jobs:jobs,reviewExists:reviewExists,operation:.nativeGeneration) ?? nativeReadiness(job,alreadyDispatched:alreadyDispatched(job))
        }
        if let configuration = job.h3ABConfiguration {
            guard job.status.isPending,job.attempts.isEmpty,job.externalHistory == nil,configuration.launchAuthorized,
                  job.h3InputPreparation?.status != "failed" else { return .waiting(.abPreparation,"A/B 输入或授权尚未就绪") }
            return .eligible(.abPreparation,"已授权的 A/B 输入，可自动准备并检查")
        }
        return plannedReadiness(job,jobs:jobs,reviewExists:reviewExists)
    }
    static func orderedPlanned(_ jobs: [ShotJob]) -> [ShotJob] {
        jobs.enumerated().sorted { a,b in
            let x = a.element.h3QueuePlan!,y = b.element.h3QueuePlan!
            if x.priority != y.priority { return x.priority < y.priority }
            if x.part != y.part { return x.part < y.part }
            return a.offset < b.offset
        }.map(\.element)
    }
    static func fixtureCandidates(_ jobs: [ShotJob]) -> [ShotJob] {
        jobs.filter { $0.status == .queued && $0.engine == .fixture && $0.externalHistory == nil && $0.supersededBy == nil }
    }
    static func evaluatedPending(_ jobs: [ShotJob],excluding currentID: UUID? = nil,preferFixtures: Bool = false,
                                 reviewExists: (UUID) -> Bool,alreadyDispatched: (ShotJob) -> Bool,
                                 inputReviewExists: (UUID) -> Bool = { _ in false }) -> [QueueCandidate] {
        let pending = jobs.filter { $0.status.isPending && $0.externalHistory == nil && $0.supersededBy == nil && $0.id != currentID }
        let planned = orderedPlanned(pending.filter { $0.h3QueuePlan != nil })
        let otherH3 = pending.filter { $0.engine == .h3 && $0.h3QueuePlan == nil }
        let fixtures = fixtureCandidates(pending)
        let ordered = preferFixtures ? fixtures + planned + otherH3 : planned + otherH3 + fixtures
        return ordered.map { .init(job:$0,readiness:readiness($0,jobs:jobs,reviewExists:reviewExists,alreadyDispatched:alreadyDispatched,inputReviewExists:inputReviewExists)) }
    }
}

extension TaskStore {
    func plannedReadiness(_ job: ShotJob) -> QueueReadiness {
        QueueScheduling.plannedReadiness(job,jobs:state.jobs) { FileManager.default.fileExists(atPath:H3QueueExecution.reviewURL(workspace:root,id:$0).path) }
    }
    var plannedPreparationCandidates: [ShotJob] { QueueScheduling.orderedPlanned(state.jobs.filter { plannedReadiness($0).ready }) }
    var fixtureQueueCandidates: [ShotJob] { QueueScheduling.fixtureCandidates(state.jobs) }
    var queueCandidates: [QueueCandidate] {
        QueueScheduling.evaluatedPending(state.jobs,excluding:ownedActiveTask?.id,preferFixtures:ownedActiveTask?.engine == .fixture,
            reviewExists:{ FileManager.default.fileExists(atPath:H3QueueExecution.reviewURL(workspace:self.root,id:$0).path) },
            alreadyDispatched:{ self.alreadyDispatched($0) },
            inputReviewExists:{ FileManager.default.fileExists(atPath:self.firstReviewURL($0).path) })
    }
    var pixelReviewCandidates: [ShotJob] { queueCandidates.filter { $0.readiness.ready && $0.readiness.operation == .inputReview }.map(\.job) }
    func alreadyDispatched(_ job: ShotJob) -> Bool {
        job.h3Binding.map { FileManager.default.fileExists(atPath:root.appendingPathComponent("h3-dispatch/" + $0.jobSHA256 + ".json").path) } ?? false
    }
    func dependencyBlocker(_ job: ShotJob,operation: QueueOperation) -> QueueReadiness? {
        QueueScheduling.dependencyBlocker(job,jobs:state.jobs,reviewExists:{ FileManager.default.fileExists(atPath:H3QueueExecution.reviewURL(workspace:self.root,id:$0).path) },operation:operation)
    }
    func nativeReadiness(_ job: ShotJob) -> QueueReadiness {
        dependencyBlocker(job,operation:.nativeGeneration) ?? QueueScheduling.nativeReadiness(job,alreadyDispatched:alreadyDispatched(job))
    }
}
