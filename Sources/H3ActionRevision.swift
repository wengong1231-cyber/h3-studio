import Foundation

/// A prompt-only overlay. The original queue plan and manifest remain immutable.
/// Each revision keeps the exact previous failed state, prompt, proposal and QA.
struct H3ActionRevision: Codable, Equatable {
    var number: Int
    var actionGoal: String
    var requestSourcePath: String
    var requestSHA256: String
    var directory: String
    var promptSHA256: String
    var previousProposalPath: String
    var previousProposalSHA256: String
    var previousPromptSHA256: String
    var previousReviewSHA256: String
    var previousStateSHA256: String
    var promptPath: String { directory + "/prompt.txt" }
    var proposalPath: String { directory + "/queue-proposal.json" }
    var reviewPath: String { directory + "/pixel-review.json" }
    var frozenFiles: [String:String] {
        [directory + "/revision-request.json":requestSHA256,
         directory + "/previous-proposal.json":previousProposalSHA256,
         directory + "/previous-prompt.txt":previousPromptSHA256,
         directory + "/previous-pixel-review.json":previousReviewSHA256,
         directory + "/previous-job.json":previousStateSHA256,promptPath:promptSHA256]
    }
    static func directory(workspace: String,id: UUID,number: Int) -> String {
        workspace + "/h3-config/" + id.uuidString + "/action-revisions/r\(number)"
    }
    static var knownRequest: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex/2026-10-06/task-6/s35-p01-airborne-revision-handoff.json")
    }

    func validate(source: H3QueueExecutionSource,runtime: H3Runtime,requireUserProvenance: Bool = true) throws {
        guard (2...100).contains(number),(12...4000).contains(actionGoal.utf8.count),
              directory == Self.directory(workspace:source.appWorkspace,id:source.appJobID,number:number),
              ModelStatusReader.isHash(requestSHA256,length:64),ModelStatusReader.isHash(promptSHA256,length:64) else {
            throw StudioError.invalid("动作修订层身份或目录无效。")
        }
        _ = try H3Files.inside(directory,source.appWorkspace + "/h3-config/" + source.appJobID.uuidString)
        for (path,hash) in frozenFiles {
            guard ModelStatusReader.isHash(hash,length:64),try WorkspaceDigest.sha256(H3Files.safe(path)) == hash else {
                throw StudioError.invalid("动作修订历史或提示词指纹变化。")
            }
        }
        let data = try H3Files.read(H3Files.safe(directory + "/previous-proposal.json"))
        let previous = try JSONDecoder().decode(H3QueueExecutionDescriptor.self,from:data)
        var base = source;base.actionRevision = previous.source.actionRevision
        guard base == previous.source,number == (previous.source.actionRevision?.number ?? 1) + 1 else {
            throw StudioError.invalid("动作修订改变了来源、帧位或生成参数。")
        }
        let original = try H3Files.read(H3Files.safe(previousProposalPath))
        guard original == data else { throw StudioError.invalid("原任务提案变化，动作修订未被采用。") }
        guard let request = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(directory + "/revision-request.json"),limit:32768)) as? [String:Any],
              request["appJobID"] as? String == source.appJobID.uuidString,request["requestID"] as? String == source.plan.requestID,
              let change = request["requestedRevision"] as? [String:Any],change["actionGoal"] as? String == actionGoal,
              change["promptSHA256"] as? String == promptSHA256,let text = change["promptUTF8"] as? String,
              try H3Files.read(H3Files.safe(promptPath),limit:32768) == Data(text.utf8) else {
            throw StudioError.invalid("动作修订与冻结的助手请求不一致。")
        }
        let parsed = try H3QueueExecution.parse(data,sourcePath:previousProposalPath,runtime:runtime,requireUserProvenance:requireUserProvenance).proposal
        let oldJob = try JSONDecoder().decode(ShotJob.self,from:H3Files.read(H3Files.safe(directory + "/previous-job.json")))
        guard oldJob.id == source.appJobID,oldJob.status == .failed,oldJob.attempts.isEmpty,oldJob.h3Binding == nil,
              oldJob.h3QueuePlan == source.plan,oldJob.h3FirstProposal?.sourceSHA256 == previousProposalSHA256,
              oldJob.h3FirstProposal?.promptSHA256 == previousPromptSHA256,let input = oldJob.h3FirstProposal?.input,
              parsed.sourceMediaSHA256 == oldJob.h3FirstProposal?.sourceMediaSHA256 else {
            throw StudioError.invalid("修订前任务不是未领取的失败输入。")
        }
        var prior = parsed;prior.input = input
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        prior.pixelReview = try decoder.decode(H3FirstPixelReview.self,from:H3Files.read(H3Files.safe(directory + "/previous-pixel-review.json"),limit:16384))
        guard prior.pixelReview?.appJobID == source.appJobID,prior.reviewBindingsMatch,prior.pixelReview?.status == "fail" else {
            throw StudioError.invalid("修订没有保留原失败画面检查。")
        }
    }

    static func writeImmutable(_ bytes: Data,to path: String) throws {
        let url = try H3Files.safe(path)
        if FileManager.default.fileExists(atPath:path) {
            guard try H3Files.read(url,limit:2_097_152) == bytes else { throw StudioError.invalid("修订目录已有不同记录，未覆盖。") }
        } else { try bytes.write(to:url,options:.withoutOverwriting) }
    }

    static func prepare(job: ShotJob,requestURL: URL,reviewURL: URL,workspace: URL,runtime: H3Runtime,control: H3PreparationControl) throws -> H3FirstProposal {
        try control.check()
        guard job.status == .failed,job.engine == .h3,job.externalHistory == nil,job.attempts.isEmpty,job.h3Binding == nil,
              let old = job.h3FirstProposal,let input = old.input,let source = old.queueExecution,old.launchAuthorized,
              source.appJobID == job.id,source.appWorkspace == workspace.path,source.plan == job.h3QueuePlan else {
            throw StudioError.invalid("只允许修订未领取、无原生尝试的失败队列任务。")
        }
        let candidate = runtime.workDirectory + "/candidates/app-" + old.segment + "-" + job.id.uuidString.lowercased()
        guard !FileManager.default.fileExists(atPath:candidate) else { throw StudioError.invalid("该任务已有候选或领取目录，禁止修订。") }
        let bytes = try H3Files.read(H3Files.safe(requestURL.path),limit:32768)
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              object["schema"] as? String == "jingsheng-assistant-action-revision-handoff-v1",
              object["status"] as? String == "draft_for_App_developer_not_a_runtime_supported_request",
              object["appJobID"] as? String == job.id.uuidString,object["requestID"] as? String == source.plan.requestID,
              object["shot"] as? Int == old.shot,object["part"] as? Int == old.part,
              let baseline = object["baseline"] as? [String:Any],baseline["status"] as? String == "failed",baseline["attempts"] as? Int == 0,
              baseline["manifestSnapshotPath"] as? String == source.plan.manifestSnapshotPath,
              baseline["manifestSHA256"] as? String == source.plan.manifestSHA256,
              baseline["proposalPath"] as? String == old.sourcePath,baseline["proposalSHA256"] as? String == old.sourceSHA256,
              baseline["promptPath"] as? String == old.promptPath,baseline["promptSHA256"] as? String == old.promptSHA256,
              baseline["failureReviewPath"] as? String == reviewURL.path,let reviewHash = baseline["failureReviewSHA256"] as? String,
              let request = object["requestedRevision"] as? [String:Any],request["promptOnlyRevisionOfSameTask"] as? Bool == true,
              let goal = request["actionGoal"] as? String,(12...4000).contains(goal.utf8.count),
              let prompt = request["promptUTF8"] as? String,(12...32768).contains(prompt.utf8.count),
              let promptHash = request["promptSHA256"] as? String,H3ABConfigurationReader.digest(Data(prompt.utf8)) == promptHash,
              let draftPath = request["promptDraftPath"] as? String,
              let frozen = object["frozenInputs"] as? [String:Any],
              frozen["sourceMediaPath"] as? String == old.sourceMediaPath,frozen["sourceMediaSHA256"] as? String == old.sourceMediaSHA256,
              frozen["sourceFrameIndex"] as? Int == old.sourceFrameIndex,
              frozen["originalPath"] as? String == input.originalPath,frozen["originalSHA256"] as? String == input.originalSHA256,
              frozen["normalizedPath"] as? String == input.normalizedPath,frozen["normalizedSHA256"] as? String == input.normalizedSHA256,
              frozen["seed"] as? Int == old.seed,frozen["selectedRawHalfOpen"] as? [Int] == [old.selectedRawStart,old.selectedRawEnd],
              frozen["destinationGlobalHalfOpen"] as? [Int] == [old.destinationGlobalStart,old.destinationGlobalEnd],
              let profile = frozen["profile"] as? [String:Any],
              try JSONDecoder().decode(H3Profile.self,from:JSONSerialization.data(withJSONObject:profile)) == old.profile else {
            throw StudioError.invalid("助手动作修订没有绑定当前任务、旧失败身份或冻结输入。")
        }
        let draft = try H3Files.inside(draftPath,requestURL.deletingLastPathComponent().path)
        guard try H3Files.read(draft,limit:32768) == Data(prompt.utf8) else { throw StudioError.invalid("修订提示词草稿与请求不同。") }
        let previousData = try H3Files.read(H3Files.inside(old.sourcePath,workspace.path + "/h3-config"))
        guard H3ABConfigurationReader.digest(previousData) == old.sourceSHA256 else { throw StudioError.invalid("原提案指纹变化。") }
        var parsed = try H3QueueExecution.parse(previousData,sourcePath:old.sourcePath,runtime:runtime).proposal
        let previousPrompt = try H3Files.read(H3Files.safe(old.promptPath),limit:32768)
        let review = try H3Files.read(H3Files.safe(reviewURL.path),limit:16384)
        guard H3ABConfigurationReader.digest(previousPrompt) == old.promptSHA256,H3ABConfigurationReader.digest(review) == reviewHash else {
            throw StudioError.invalid("旧提示词或失败回执变化，未修订。")
        }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        parsed.input = input;parsed.pixelReview = try decoder.decode(H3FirstPixelReview.self,from:review)
        guard parsed.reviewBindingsMatch,parsed.pixelReview?.appJobID == job.id,parsed.pixelReview?.status == "fail" else { throw StudioError.invalid("原画面检查不是本任务的失败检查。") }
        try H3SourceFrames.technicalImage(input.originalPath,hash:input.originalSHA256,width:old.sourceWidth,height:old.sourceHeight)
        try H3SourceFrames.technicalImage(input.normalizedPath,hash:input.normalizedSHA256,width:768,height:448)
        try control.check()
        let number = (source.actionRevision?.number ?? 1) + 1,directory = Self.directory(workspace:workspace.path,id:job.id,number:number)
        _ = try H3Files.inside(directory,workspace.path + "/h3-config")
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        var history = job;history.h3FirstProposal?.pixelReview = parsed.pixelReview
        let previousState = try encoder.encode(history)
        let revision = Self(number:number,actionGoal:goal,requestSourcePath:requestURL.path,requestSHA256:H3ABConfigurationReader.digest(bytes),
            directory:directory,promptSHA256:promptHash,previousProposalPath:old.sourcePath,previousProposalSHA256:old.sourceSHA256,
            previousPromptSHA256:old.promptSHA256,previousReviewSHA256:reviewHash,previousStateSHA256:H3ABConfigurationReader.digest(previousState))
        for (name,data) in [("revision-request.json",bytes),("previous-proposal.json",previousData),("previous-prompt.txt",previousPrompt),
                            ("previous-pixel-review.json",review),("previous-job.json",previousState),("prompt.txt",Data(prompt.utf8))] {
            try control.check();try writeImmutable(data,to:directory + "/" + name)
        }
        var updatedSource = source;updatedSource.actionRevision = revision
        var descriptor = try JSONDecoder().decode(H3QueueExecutionDescriptor.self,from:previousData);descriptor.source = updatedSource
        let data = try encoder.encode(descriptor)
        var prepared = try H3QueueExecution.parse(data,sourcePath:revision.proposalPath,runtime:runtime).proposal
        try control.check();try writeImmutable(data,to:revision.proposalPath)
        prepared.snapshotPath = revision.proposalPath
        return prepared
    }
}
