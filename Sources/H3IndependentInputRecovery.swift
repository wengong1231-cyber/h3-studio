import Foundation

struct H3IndependentInputRecovery: Codable, Equatable, Identifiable {
    var id: UUID
    var directory: String
    var recordSHA256: String
    var previousJobSHA256: String
    var recoveredAt: Date
}

enum H3IndependentInputRecoveryReader {
    static let legacyStage = "前段候选已拒绝 · 旧端点与旧QA不能接续"
    static func rejectedEarlierJobs(_ job: ShotJob,jobs: [ShotJob]) -> [ShotJob] {
        guard let plan = job.h3QueuePlan else { return [] }
        return jobs.filter { other in
            other.id != job.id && other.supersededBy == nil && other.externalHistory == nil &&
            other.h3QueuePlan?.shot == plan.shot && (other.h3QueuePlan?.part ?? Int.max) < plan.part &&
            other.h3VideoRejection != nil && !H3VideoRejectionScope.affectedIDs(of:other,jobs:jobs).contains(job.id)
        }
    }
    static func eligible(_ job: ShotJob,jobs: [ShotJob]) -> Bool {
        guard job.status == .blocked,job.stage == legacyStage,job.engine == .h3,
              job.externalHistory == nil,job.supersededBy == nil,job.attempts.isEmpty,job.candidate == nil,
              job.h3Binding == nil,job.h3VideoRejection == nil,
              let plan = job.h3QueuePlan,plan.dependencyRequestID == nil,plan.dependencyRawIndex == nil,
              let proposal = job.h3FirstProposal,proposal.launchAuthorized,proposal.input != nil,
              let source = proposal.queueExecution,source.appJobID == job.id,source.plan == plan,
              source.endpoint == nil,source.receiptRebind == nil,
              job.h3InputPreparation?.status == "completed",
              job.h3AutomaticWorkflow?.phase == "pixel_qa",job.h3AutomaticWorkflow?.status == "waiting",
              job.h3AutomaticWorkflow?.automaticContinuationAuthorized == false else { return false }
        return !rejectedEarlierJobs(job,jobs:jobs).isEmpty
    }
    struct Prepared {
        var recovery: H3IndependentInputRecovery
        var previousReview: Data?
    }
    static func prepare(job: ShotJob,jobs: [ShotJob],reviewURL: URL,workspace: URL,runtime: H3Runtime) throws -> Prepared {
        guard eligible(job,jobs:jobs),let proposal = job.h3FirstProposal,let input = proposal.input,
              proposal.queueExecution?.appWorkspace == workspace.path else {
            throw StudioError.invalid("只恢复被旧拒绝逻辑误阻塞的独立输入；取消、真实依赖和已领取任务保持原样。")
        }
        let candidate = runtime.workDirectory + "/candidates/app-" + proposal.segment + "-" + job.id.uuidString.lowercased()
        guard !FileManager.default.fileExists(atPath:candidate) else { throw StudioError.invalid("发现领取或候选目录，未恢复输入。") }
        let bytes = try H3Files.read(H3Files.inside(proposal.sourcePath,workspace.path + "/h3-config"))
        guard H3ABConfigurationReader.digest(bytes) == proposal.sourceSHA256 else { throw StudioError.invalid("输入提案已变化。") }
        var parsed = try H3QueueExecution.parse(bytes,sourcePath:proposal.sourcePath,runtime:runtime).proposal
        parsed.snapshotPath = proposal.snapshotPath;parsed.input = input;parsed.pixelReview = proposal.pixelReview
        guard parsed == proposal,proposal.queueExecution?.staticInput == job.h3StaticBinding,
              try WorkspaceDigest.sha256(H3Files.safe(proposal.sourceMediaPath)) == proposal.sourceMediaSHA256,
              try WorkspaceDigest.sha256(H3Files.safe(input.extractionReceiptPath)) == input.extractionReceiptSHA256 else {
            throw StudioError.invalid("实际来源、归一回执或当前任务身份不同，未恢复。")
        }
        try H3SourceFrames.technicalImage(input.originalPath,hash:input.originalSHA256,width:input.originalWidth,height:input.originalHeight)
        try H3SourceFrames.technicalImage(input.normalizedPath,hash:input.normalizedSHA256,width:768,height:448)
        let earlier = rejectedEarlierJobs(job,jobs:jobs)
        var rejectionHashes: [String:String] = [:]
        for rejected in earlier {
            guard let receipt = try H3VideoRejectionReader.read(workspace:workspace,id:rejected.id),receipt == rejected.h3VideoRejection else {
                throw StudioError.invalid("此前拒绝记录与任务不符，未恢复。")
            }
            rejectionHashes[rejected.id.uuidString] = receipt.receiptSHA256
        }
        _ = try H3Files.inside(reviewURL.path,workspace.path + "/h3-config/" + job.id.uuidString)
        let priorReview = FileManager.default.fileExists(atPath:reviewURL.path) ? try H3Files.read(reviewURL,limit:16384) : nil
        let id = UUID(),directory = workspace.path + "/h3-config/" + job.id.uuidString + "/independent-input-recoveries/" + id.uuidString
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let previous = try encoder.encode(job),previousSHA = H3ABConfigurationReader.digest(previous)
        let recoveredAt = Date()
        var record: [String:Any] = ["schema":"jingsheng-App-independent-input-recovery-v1","id":id.uuidString,
            "appJobID":job.id.uuidString,"requestID":job.h3QueuePlan!.requestID,"previousJobSHA256":previousSHA,
            "proposalSHA256":proposal.sourceSHA256,"originalSHA256":input.originalSHA256,"normalizedSHA256":input.normalizedSHA256,
            "promptSHA256":proposal.promptSHA256,"preparationReceiptSHA256":input.extractionReceiptSHA256,
            "verifiedIndependentOfRejections":rejectionHashes,"source":"AppUI","actorKind":"unknown",
            "inputReviewPassed":false,"videoAccepted":false,"nativeDispatched":false,
            "recoveredAt":ISO8601DateFormatter().string(from:recoveredAt)]
        if let priorReview { record["previousReviewSHA256"] = H3ABConfigurationReader.digest(priorReview) }
        let recordBytes = try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys])
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        try H3ActionRevision.writeImmutable(previous,to:directory + "/previous-job.json")
        if let priorReview { try H3ActionRevision.writeImmutable(priorReview,to:directory + "/previous-pixel-review.json") }
        try H3ActionRevision.writeImmutable(recordBytes,to:directory + "/record.json")
        return .init(recovery:.init(id:id,directory:directory,recordSHA256:H3ABConfigurationReader.digest(recordBytes),previousJobSHA256:previousSHA,recoveredAt:recoveredAt),previousReview:priorReview)
    }
}

extension TaskStore {
    func hasIndependentInputRecovery(_ job: ShotJob) -> Bool { H3IndependentInputRecoveryReader.eligible(job,jobs:state.jobs) }
    func canRecoverIndependentInput(_ id: UUID) -> Bool {
        singleGeneratorIdle && state.jobs.first(where:{ $0.id == id }).map(hasIndependentInputRecovery) == true
    }
    func recoverIndependentInput(_ id: UUID) async throws {
        guard canRecoverIndependentInput(id),let original = state.jobs.first(where:{ $0.id == id }) else {
            throw StudioError.invalid("当前不能恢复独立输入；运行任务、明确取消和真实验收依赖保持原样。")
        }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        configurationReadOperation = "核对独立来源与旧拒绝记录，保存恢复审计"
        let jobs = state.jobs,workspace = root,runtime = h3Runtime,reviewURL = firstReviewURL(id)
        let prepared = try await Task.detached(priority:.utility) {
            try H3IndependentInputRecoveryReader.prepare(job:original,jobs:jobs,reviewURL:reviewURL,workspace:workspace,runtime:runtime)
        }.value
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        guard !shuttingDown,let index = state.jobs.firstIndex(where:{ $0.id == id }),
              H3ABConfigurationReader.digest(try encoder.encode(state.jobs[index])) == prepared.recovery.previousJobSHA256,
              hasIndependentInputRecovery(state.jobs[index]),
              H3IndependentInputRecoveryReader.rejectedEarlierJobs(state.jobs[index],jobs:state.jobs).map(\.h3VideoRejection) ==
              H3IndependentInputRecoveryReader.rejectedEarlierJobs(original,jobs:jobs).map(\.h3VideoRejection) else {
            throw StudioError.invalid("恢复期间任务或拒绝来源变化，审计已保留但未恢复。")
        }
        let currentReview = FileManager.default.fileExists(atPath:reviewURL.path) ? try H3Files.read(reviewURL,limit:16384) : nil
        guard currentReview == prepared.previousReview else { throw StudioError.invalid("图审在恢复期间变化，未覆盖。") }
        if currentReview != nil { try FileManager.default.removeItem(at:reviewURL) }
        state.jobs[index].h3FirstProposal?.pixelReview = nil
        state.jobs[index].h3AutomaticWorkflow?.automaticContinuationAuthorized = true
        state.jobs[index].h3InputRecoveries = (original.h3InputRecoveries ?? []) + [prepared.recovery]
        state.jobs[index].stage = "独立输入已恢复 · 等待新的实际图审"
        state.jobs[index].error = nil;state.jobs[index].progress = nil;state.jobs[index].updatedAt = Date()
        state.jobs[index].logTail.append("App 恢复独立输入：" + prepared.recovery.directory + "；已验证无被拒绝端点依赖。旧状态和图审保留，需新图审；暂停不变，未启动GPU。")
        persist()
        if let fault = storageFault {
            state.jobs[index] = original
            if let currentReview { try currentReview.write(to:reviewURL,options:.withoutOverwriting) }
            throw StudioError.invalid(fault)
        }
        notice = "独立输入已恢复，旧记录已保存。请导入实际输入图审；没有接受视频或启动生成。"
    }
}
