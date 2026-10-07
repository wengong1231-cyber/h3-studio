import Foundation

/// Immutable bridge for a pre-dispatch continuation whose acceptance source
/// was supplemented. It changes neither the action revision nor content.
struct H3ReceiptRebind: Codable, Equatable {
    var schema = "jingsheng-App-acceptance-source-rebind-v1"
    var id: UUID
    var appJobID: UUID
    var directory: String
    var originalProposalPath: String
    var originalProposalSHA256: String
    var previousJobSHA256: String
    var previousPixelReviewSHA256: String
    var previousPreparationSHA256: String
    var previousAcceptanceSHA256: String
    var currentAcceptanceSHA256: String
    var recordedAt: Date
    var origin = "app_rebind_action"
    var actorKind = "unknown"
    var auditSHA256: String?
    var proposalPath: String { directory + "/queue-proposal.json" }
    var reviewPath: String { directory + "/pixel-review.json" }
    var frozenFiles: [String:String] {
        [directory + "/previous-proposal.json":originalProposalSHA256,
         directory + "/previous-job.json":previousJobSHA256,
         directory + "/previous-pixel-review.json":previousPixelReviewSHA256,
         directory + "/previous-preparation.json":previousPreparationSHA256,
         directory + "/previous-acceptance.json":previousAcceptanceSHA256,
         directory + "/rebind-audit.json":auditSHA256 ?? ""]
    }
    func auditBytes() throws -> Data {
        var body = self;body.auditSHA256 = nil
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(body)
    }
    static func sameAcceptedContent(_ a: H3QueueEndpointReview,_ b: H3QueueEndpointReview) -> Bool {
        a.schema == b.schema && a.status == "pass" && b.status == "pass"
            && a.appJobID == b.appJobID && a.requestID == b.requestID && a.nativeJobSHA256 == b.nativeJobSHA256
            && a.clipSHA256 == b.clipSHA256 && a.reportSHA256 == b.reportSHA256
            && a.selectedRawHalfOpen == b.selectedRawHalfOpen && a.endpointRawIndex == b.endpointRawIndex
            && a.endpointSHA256 == b.endpointSHA256 && a.actionRevisionNumber == b.actionRevisionNumber
            && a.acceptancePromptSHA256 == b.acceptancePromptSHA256 && a.acceptanceStaticBindingSHA256 == b.acceptanceStaticBindingSHA256
    }
    static func assertUnclaimed(_ job: ShotJob,workspace: URL,runtime: H3Runtime) throws {
        guard job.status == .failed,job.supersededBy == nil,job.externalHistory == nil,job.attempts.isEmpty,
              job.h3Binding == nil,job.h3VideoRejection == nil,job.h3AutomaticWorkflow?.phase == "input_freeze",
              let proposal = job.h3FirstProposal,proposal.launchAuthorized,proposal.reviewReady,
              proposal.queueExecution?.endpoint != nil,proposal.queueExecution?.actionRevision == nil,
              proposal.queueExecution?.staticInput == nil,proposal.queueExecution?.receiptRebind == nil else {
            throw StudioError.invalid("仅支持未领取且图审已通过的接受来源变化；输出或动作修订需单独重做。")
        }
        try assertNoClaim(job,workspace:workspace,runtime:runtime)
    }
    static func assertNoClaim(_ job: ShotJob,workspace: URL,runtime: H3Runtime) throws {
        guard job.attempts.isEmpty,job.h3Binding == nil,let proposal = job.h3FirstProposal else {
            throw StudioError.invalid("此段已有生成尝试或冻结绑定，不能重复恢复。")
        }
        let native = runtime.workDirectory + "/candidates/app-" + proposal.segment + "-" + job.id.uuidString.lowercased()
        guard !FileManager.default.fileExists(atPath:native),
              !FileManager.default.fileExists(atPath:workspace.path + "/candidates/" + job.id.uuidString) else {
            throw StudioError.invalid("此段已存在原生或应用尝试目录，不能重绑定。")
        }
        let ledger = workspace.appendingPathComponent("h3-dispatch")
        if FileManager.default.fileExists(atPath:ledger.path) {
            let entries = try FileManager.default.contentsOfDirectory(at:ledger,includingPropertiesForKeys:nil)
            guard entries.count <= 10000 else { throw StudioError.invalid("领取目录超限，无法确认本段尚未执行。") }
            for entry in entries where entry.pathExtension == "json" {
                let dispatch = try JSONDecoder().decode(H3DispatchReceipt.self,from:H3Files.read(H3Files.inside(entry.path,ledger.path),limit:32768))
                guard dispatch.appJobID != job.id else { throw StudioError.invalid("此 App 段已有持久领取，不能重绑定或重投。") }
            }
        }
    }
    struct Assessment {
        var descriptor: H3QueueExecutionDescriptor
        var previousProposal: Data
        var previousJob: Data
        var previousReview: Data
        var previousPreparation: Data
        var previousAcceptance: Data
        var currentAcceptanceSHA256: String
    }
    static func assess(job: ShotJob,predecessor: ShotJob,workspace: URL,runtime: H3Runtime) throws -> Assessment {
        try assertUnclaimed(job,workspace:workspace,runtime:runtime)
        let old = job.h3FirstProposal!,source = old.queueExecution!,endpoint = source.endpoint!
        guard source.appJobID == job.id,source.appWorkspace == workspace.path,source.plan == job.h3QueuePlan,
              predecessor.id == endpoint.appJobID,predecessor.supersededBy == nil,predecessor.externalHistory == nil,
              predecessor.status == .completed,predecessor.h3Outcome?.technicalPass == true,
              predecessor.h3Binding?.jobSHA256 == endpoint.jobSHA256,
              predecessor.actionRevisionNumber == (try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(H3Files.safe(endpoint.jobPath)))).app_first_task?.proposal.queueExecution?.actionRevision?.number ?? 1 else {
            throw StudioError.invalid("前段身份、内容或动作修订已变化，不能作为来源补录。")
        }
        let previous = try H3Files.read(H3Files.inside(old.sourcePath,workspace.path + "/h3-config"))
        guard H3ABConfigurationReader.digest(previous) == old.sourceSHA256 else { throw StudioError.invalid("原提案指纹变化。") }
        var descriptor = try JSONDecoder().decode(H3QueueExecutionDescriptor.self,from:previous)
        guard descriptor.source == source else { throw StudioError.invalid("原提案与失败任务不一致。") }
        let receipt = H3QueueExecution.reviewURL(workspace:workspace,id:endpoint.appJobID)
        let currentBytes = try H3Files.read(H3Files.inside(receipt.path,workspace.path + "/h3-queue-reviews"),limit:16384)
        let currentHash = H3ABConfigurationReader.digest(currentBytes)
        guard currentHash != endpoint.reviewSHA256 else { throw StudioError.invalid("接受回执没有变化，无需重绑定。") }
        let history = receipt.deletingLastPathComponent().appendingPathComponent("receipt-history/" + endpoint.reviewSHA256 + ".json")
        let archived = try H3Files.read(H3Files.inside(history.path,receipt.deletingLastPathComponent().path),limit:16384)
        guard H3ABConfigurationReader.digest(archived) == endpoint.reviewSHA256 else { throw StudioError.invalid("原接受回执归档缺失或指纹不同。") }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let priorReview = try decoder.decode(H3QueueEndpointReview.self,from:archived)
        let currentReview = try decoder.decode(H3QueueEndpointReview.self,from:currentBytes)
        guard sameAcceptedContent(priorReview,currentReview),
              try H3AcceptanceAuthority.valid(currentReview,workspace:workspace,runtime:runtime,requireContinuation:true,
                  successorAppJobID:job.id,successorRequestID:source.plan.requestID) else {
            throw StudioError.invalid("变化涉及输出、修订或接受撤销，不能按来源补录恢复。")
        }
        descriptor.source.endpoint?.reviewSHA256 = currentHash
        let (_,_,manifestJobs) = try H3QueueExecution.manifest(descriptor.source,runtime:runtime)
        try H3QueueExecution.validateEndpoint(descriptor.source.endpoint!,source:descriptor.source,runtime:runtime,jobs:manifestJobs)
        let qaURL = URL(fileURLWithPath:source.appWorkspace + "/h3-config/" + job.id.uuidString + "/pixel-review.json")
        let qaBytes = try H3Files.read(H3Files.inside(qaURL.path,workspace.path + "/h3-config"),limit:16384)
        let qa = try decoder.decode(H3FirstPixelReview.self,from:qaBytes)
        guard qa == old.pixelReview,qa.status == "pass" else { throw StudioError.invalid("原图审没有绑定同一输入，不沿用旧图审。") }
        let input = old.input!
        try H3SourceFrames.technicalImage(input.originalPath,hash:endpoint.imageSHA256,width:old.sourceWidth,height:old.sourceHeight)
        try H3SourceFrames.technicalImage(input.normalizedPath,hash:endpoint.imageSHA256,width:old.profile.width,height:old.profile.height)
        let preparation = try H3Files.read(H3Files.inside(input.extractionReceiptPath,runtime.workDirectory + "/app-inputs"),limit:32768)
        guard H3ABConfigurationReader.digest(preparation) == input.extractionReceiptSHA256,
              input.originalSHA256 == endpoint.imageSHA256,input.normalizedSHA256 == endpoint.imageSHA256 else { throw StudioError.invalid("原准备输入指纹变化。") }
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return .init(descriptor:descriptor,previousProposal:previous,previousJob:try encoder.encode(job),previousReview:qaBytes,
            previousPreparation:preparation,previousAcceptance:archived,currentAcceptanceSHA256:currentHash)
    }
    static func prepare(job: ShotJob,predecessor: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3FirstProposal {
        let assessment = try assess(job:job,predecessor:predecessor,workspace:workspace,runtime:runtime)
        let id = UUID(),directory = workspace.path + "/h3-config/" + job.id.uuidString + "/receipt-rebinds/" + id.uuidString
        var record = Self(id:id,appJobID:job.id,directory:directory,originalProposalPath:job.h3FirstProposal!.sourcePath,
            originalProposalSHA256:job.h3FirstProposal!.sourceSHA256,previousJobSHA256:H3ABConfigurationReader.digest(assessment.previousJob),
            previousPixelReviewSHA256:H3ABConfigurationReader.digest(assessment.previousReview),previousPreparationSHA256:H3ABConfigurationReader.digest(assessment.previousPreparation),
            previousAcceptanceSHA256:job.h3FirstProposal!.queueExecution!.endpoint!.reviewSHA256,
            currentAcceptanceSHA256:assessment.currentAcceptanceSHA256,recordedAt:Date())
        let audit = try record.auditBytes();record.auditSHA256 = H3ABConfigurationReader.digest(audit)
        _ = try H3Files.inside(directory,workspace.path + "/h3-config/" + job.id.uuidString)
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        for (name,bytes) in [("previous-proposal.json",assessment.previousProposal),("previous-job.json",assessment.previousJob),
            ("previous-pixel-review.json",assessment.previousReview),("previous-preparation.json",assessment.previousPreparation),
            ("previous-acceptance.json",assessment.previousAcceptance),("rebind-audit.json",audit)] {
            try bytes.write(to:H3Files.safe(directory + "/" + name),options:.withoutOverwriting)
        }
        var descriptor = assessment.descriptor;descriptor.source.receiptRebind = record
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let bytes = try encoder.encode(descriptor)
        var proposal = try H3QueueExecution.parse(bytes,sourcePath:record.proposalPath,runtime:runtime).proposal
        try bytes.write(to:H3Files.safe(record.proposalPath),options:.withoutOverwriting)
        proposal.snapshotPath = record.proposalPath;return proposal
    }
    func validate(source: H3QueueExecutionSource,runtime: H3Runtime) throws {
        guard schema == "jingsheng-App-acceptance-source-rebind-v1",appJobID == source.appJobID,origin == "app_rebind_action",actorKind == "unknown",
              directory == source.appWorkspace + "/h3-config/" + appJobID.uuidString + "/receipt-rebinds/" + id.uuidString,
              source.actionRevision == nil,source.staticInput == nil,
              source.endpoint?.reviewSHA256 == currentAcceptanceSHA256,previousAcceptanceSHA256 != currentAcceptanceSHA256 else { throw StudioError.invalid("来源重绑定身份或范围无效。") }
        for (path,hash) in frozenFiles {
            guard ModelStatusReader.isHash(hash,length:64),try WorkspaceDigest.sha256(H3Files.inside(path,directory)) == hash else { throw StudioError.invalid("来源重绑定审计或原记录指纹变化。") }
        }
        guard try H3Files.read(H3Files.safe(directory + "/rebind-audit.json")) == auditBytes(),
              try WorkspaceDigest.sha256(H3Files.inside(originalProposalPath,source.appWorkspace + "/h3-config")) == originalProposalSHA256 else {
            throw StudioError.invalid("来源重绑定没有保留原提案和审计。")
        }
        let previous = try JSONDecoder().decode(H3QueueExecutionDescriptor.self,from:H3Files.read(H3Files.safe(directory + "/previous-proposal.json")))
        var content = source;content.receiptRebind = nil;content.endpoint?.reviewSHA256 = previousAcceptanceSHA256
        guard content == previous.source else { throw StudioError.invalid("重绑定改变了输出、端帧、提示词、修订或生成参数。") }
        let oldJob = try JSONDecoder().decode(ShotJob.self,from:H3Files.read(H3Files.safe(directory + "/previous-job.json")))
        guard oldJob.id == appJobID,oldJob.status == .failed,oldJob.attempts.isEmpty,oldJob.h3Binding == nil,
              oldJob.h3QueuePlan == source.plan,oldJob.h3FirstProposal?.queueExecution == previous.source,
              oldJob.h3FirstProposal?.sourceSHA256 == originalProposalSHA256 else { throw StudioError.invalid("重绑定之前已有领取或任务身份变化。") }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let qa = try decoder.decode(H3FirstPixelReview.self,from:H3Files.read(H3Files.safe(directory + "/previous-pixel-review.json")))
        guard qa == oldJob.h3FirstProposal?.pixelReview,oldJob.h3FirstProposal?.reviewReady == true,
              oldJob.h3FirstProposal?.input?.extractionReceiptSHA256 == previousPreparationSHA256 else { throw StudioError.invalid("没有保留同一图像与提示词的原有效图审。") }
        let oldAcceptance = try decoder.decode(H3QueueEndpointReview.self,from:H3Files.read(H3Files.safe(directory + "/previous-acceptance.json")))
        let current = try decoder.decode(H3QueueEndpointReview.self,from:H3Files.read(H3Files.safe(source.endpoint!.reviewPath)))
        guard Self.sameAcceptedContent(oldAcceptance,current),H3ABConfigurationReader.digest(try H3Files.read(H3Files.safe(currentReviewPath(source)))) == currentAcceptanceSHA256,
              try H3AcceptanceAuthority.valid(current,workspace:URL(fileURLWithPath:source.appWorkspace),runtime:runtime,requireContinuation:true,
                  successorAppJobID:source.appJobID,successorRequestID:source.plan.requestID) else { throw StudioError.invalid("当前接受已撤销、指纹变化或不再允许此续段。") }
    }
    private func currentReviewPath(_ source: H3QueueExecutionSource) -> String { source.endpoint!.reviewPath }
    func bridgedReview(proposal: H3FirstProposal) throws -> H3FirstPixelReview {
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        var qa = try decoder.decode(H3FirstPixelReview.self,from:H3Files.read(H3Files.safe(directory + "/previous-pixel-review.json")))
        guard let input = proposal.input,qa.appJobID == appJobID,qa.sourceMediaSHA256 == proposal.sourceMediaSHA256,
              qa.sourceFrameIndex == proposal.sourceFrameIndex,qa.promptSHA256 == proposal.promptSHA256,
              qa.originalSHA256 == input.originalSHA256,qa.normalizedSHA256 == input.normalizedSHA256,qa.status == "pass" else { throw StudioError.invalid("重新准备后的像素或提示词不同，不能沿用原图审。") }
        qa.proposalSHA256 = proposal.sourceSHA256 // Original inspection timestamp and assertions remain unchanged.
        return qa
    }
}

extension TaskStore {
    func hasAcceptanceRecoveryAction(_ job: ShotJob) -> Bool {
        guard job.supersededBy == nil,job.externalHistory == nil,job.attempts.isEmpty,job.h3Binding == nil,
              let source = job.h3FirstProposal?.queueExecution,source.endpoint != nil,
              source.actionRevision == nil,source.staticInput == nil else { return false }
        if source.receiptRebind != nil {
            return job.status.isPending && (job.h3AutomaticWorkflow == nil || job.h3AutomaticWorkflow?.phase == "pixel_qa")
        }
        return job.status == .failed && job.h3AutomaticWorkflow?.phase == "input_freeze" && job.h3FirstProposal?.reviewReady == true
    }
    func canResumeAcceptanceRebind(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),hasAcceptanceRecoveryAction(job),
              job.status.isPending,job.h3FirstProposal?.queueExecution?.receiptRebind != nil else { return false }
        return dependencyBlocker(job,operation:.firstPreparation) == nil
    }
    func canRebindAcceptanceSource(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.status == .failed,job.attempts.isEmpty,
              job.h3Binding == nil,job.supersededBy == nil,job.h3AutomaticWorkflow?.phase == "input_freeze",job.h3FirstProposal?.reviewReady == true,
              let source = job.h3FirstProposal?.queueExecution,source.actionRevision == nil,source.staticInput == nil,source.receiptRebind == nil,
              let endpoint = source.endpoint,let predecessor = currentPlannedJob(endpoint.requestID),predecessor.id == endpoint.appJobID else { return false }
        return predecessor.videoContinuationAuthorized && predecessor.h3VideoRejection == nil
    }
    func rebindAcceptanceSource(_ id: UUID) async {
        if let job = state.jobs.first(where:{ $0.id == id }),hasAcceptanceRecoveryAction(job),job.status.isPending {
            await resumeAcceptanceRebind(id);return
        }
        guard canRebindAcceptanceSource(id),let index = state.jobs.firstIndex(where:{ $0.id == id }),
              let request = state.jobs[index].h3QueuePlan?.dependencyRequestID,let predecessor = currentPlannedJob(request) else { return }
        let old = state.jobs[index],workspace = root,runtime = h3Runtime
        abConfigurationBusy = true;configurationReadOperation = "核对接受来源补录与原端帧内容"
        do {
            let proposal = try await Task.detached(priority:.utility) { try H3ReceiptRebind.prepare(job:old,predecessor:predecessor,workspace:workspace,runtime:runtime) }.value
            guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].status == .failed,
                  state.jobs[i].h3FirstProposal == old.h3FirstProposal,state.jobs[i].attempts.isEmpty,state.jobs[i].h3Binding == nil else { throw StudioError.invalid("任务状态变化，审计暂存但未恢复。") }
            state.jobs[i].h3FirstProposal = proposal;state.jobs[i].h3AutomaticWorkflow = nil
            state.jobs[i].h3InputPreparation = .init(materialsStartedAt:Date(),materialsEndedAt:Date())
            state.jobs[i].status = .blocked;state.jobs[i].error = nil;state.jobs[i].executionActivity = nil
            state.jobs[i].startedAt = nil;state.jobs[i].endedAt = nil;state.jobs[i].progress = nil
            state.jobs[i].stage = "接受来源已补录 · 重新准备同一端帧"
            state.jobs[i].logTail.append("来源重绑定：原失败、提案、准备与QA已不可变归档。任务身份、动作修订、视频、端帧、提示词与生成参数保持相同；未补造用户接受。")
            persist();guard storageFault == nil else { state.jobs[i] = old;throw StudioError.invalid(storageFault!) }
            abConfigurationBusy = false
            await resumeAcceptanceRebind(id)
        } catch { abConfigurationBusy = false;notice = error.localizedDescription }
    }
    func resumeAcceptanceRebind(_ id: UUID) async {
        guard canResumeAcceptanceRebind(id),let original = state.jobs.first(where:{ $0.id == id }),
              let source = original.h3FirstProposal?.queueExecution,let rebind = source.receiptRebind else {
            notice = "接受来源已重绑；等待后台核对结束后，可继续恢复同一段。";return
        }
        let workspace = root,runtime = h3Runtime
        state.automaticLaunchesPaused = false;persist()
        guard storageFault == nil else { return }
        abConfigurationBusy = true;configurationReadOperation = "核对已保存的恢复审计"
        do {
            try await Task.detached(priority:.utility) {
                try H3ReceiptRebind.assertNoClaim(original,workspace:workspace,runtime:runtime)
                try rebind.validate(source:source,runtime:runtime)
            }.value
            guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),
                  state.jobs[i].status.isPending,state.jobs[i].h3FirstProposal == original.h3FirstProposal else {
                throw StudioError.invalid("恢复期间任务发生变化，保留审计并停止。")
            }
            abConfigurationBusy = false
            guard state.automaticLaunchesPaused != true else { notice = "恢复已暂停，审计与输入保留。";return }
            if original.h3FirstProposal?.input == nil { await startAuthorizedFirst(id) }
            guard let current = state.jobs.first(where:{ $0.id == id }),current.status.isPending,
                  let prepared = current.h3FirstProposal,prepared.input != nil else {
                notice = "恢复审计已保存，首图尚未准备；可继续恢复同一段，不会创建新任务。";return
            }
            let qa = try rebind.bridgedReview(proposal:prepared)
            let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let bytes = try encoder.encode(qa),url = try H3Files.safe(rebind.reviewPath)
            if FileManager.default.fileExists(atPath:url.path) {
                guard try H3Files.read(url,limit:16384) == bytes else { throw StudioError.invalid("恢复图审记录变化，不能覆盖。") }
            } else { try bytes.write(to:url,options:.withoutOverwriting) }
            await resumeReboundFirst(id)
        } catch { abConfigurationBusy = false;notice = error.localizedDescription }
    }
}
