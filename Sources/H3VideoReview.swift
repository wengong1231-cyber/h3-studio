import Foundation

struct H3VideoReviewState: Codable, Equatable {
    var status: String
    var receiptPath: String
    var receiptSHA256: String
    var clipSHA256: String
    var endpointPath: String
    var endpointSHA256: String
    var endpointRawIndex: Int
    var selectedRawHalfOpen: [Int]
    var evidenceID: String
    var reviewedAt: Date
    var knownVisualRisks: [String]
    var observation: String
    var provenance: H3AcceptanceProvenance? = nil
    var isTrustedAcceptance: Bool {
        status == "accepted" && (provenance?.declaresUserInstruction == true || provenance?.declaresProductAcceptance == true || provenance == .fixture)
    }
    var canAuthorizeContinuation: Bool { isTrustedAcceptance && provenance?.continuationAuthorized == true }
}

enum H3VideoReviewReader {
    static func evidence(job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> (H3QueueEndpointReview,String) {
        guard job.supersededBy == nil,job.externalHistory == nil,job.status == .completed,
              let plan = job.h3QueuePlan,let binding = job.h3Binding,binding.appTaskID == job.id,
              let outcome = job.h3Outcome,outcome.technicalPass else { throw StudioError.invalid("本段尚未技术通过，不能接受。") }
        _ = try H3FirstTaskBinding.load(H3Files.safe(binding.jobPath),runtime:runtime,requireFresh:false,allowHistoricalAcceptance:true)
        let report = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(outcome.reportPath))) as! [String:Any]
        guard report["status"] as? String == "technical_pass",report["app_job_id"] as? String == job.id.uuidString,
              report["decoded_video_frames"] as? Int == plan.profile.frames,
              let clipHash = report["clip_sha256"] as? String,try WorkspaceDigest.sha256(H3Files.safe(binding.clipPath)) == clipHash,
              report["selected_raw_half_open"] as? [Int] == [plan.selectedRawStart,plan.selectedRawEnd],
              report["continuation_endpoint_raw_index"] as? Int == plan.selectedRawEnd-1,
              let hash = report["continuation_endpoint_sha256"] as? String else { throw StudioError.invalid("候选视频与所选端点技术回执不一致。") }
        let imagePath = binding.outputDirectory + String(format:"/record/lossless-frames/frame-%04d.png",plan.selectedRawEnd-1)
        try H3SourceFrames.technicalImage(imagePath,hash:hash,width:plan.profile.width,height:plan.profile.height)
        let review = H3QueueEndpointReview(appJobID:job.id,requestID:plan.requestID,nativeJobSHA256:binding.jobSHA256,
            clipSHA256:clipHash,reportSHA256:try WorkspaceDigest.sha256(H3Files.safe(outcome.reportPath)),
            selectedRawHalfOpen:[plan.selectedRawStart,plan.selectedRawEnd],endpointRawIndex:plan.selectedRawEnd-1,
            endpointSHA256:hash,status:runtime.mode == .mock ? "pass" : "recorded",reviewerKind:runtime.mode == .mock ? "fixture" : "unknown",userEvidenceID:"",
            selectedWindowViewed:runtime.mode == .mock,endpointPixelsViewed:runtime.mode == .mock,
            observation:"App 界面操作记录。操作者身份和实际观看情况未由此按钮认证；不能据此认定用户验收或放行续段。",reviewedAt:Date(),
            provenance:runtime.mode == .mock ? .fixture : .unidentifiedUI)
        return (review,imagePath)
    }
    static func load(job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3VideoReviewState? {
        let url = H3QueueExecution.reviewURL(workspace:workspace,id:job.id)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let bytes = try H3Files.read(H3Files.inside(url.path,workspace.path + "/h3-queue-reviews"),limit:16384)
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let review = try decoder.decode(H3QueueEndpointReview.self,from:bytes),expected = try evidence(job:job,workspace:workspace,runtime:runtime)
        guard review.schema == expected.0.schema,["pass","recorded"].contains(review.status),review.appJobID == job.id,
              review.requestID == expected.0.requestID,review.nativeJobSHA256 == expected.0.nativeJobSHA256,
              review.clipSHA256 == expected.0.clipSHA256,review.reportSHA256 == expected.0.reportSHA256,
              review.endpointRawIndex == expected.0.endpointRawIndex,review.endpointSHA256 == expected.0.endpointSHA256,
              review.selectedRawHalfOpen == expected.0.selectedRawHalfOpen,
              (12...4000).contains(review.observation.utf8.count) else {
            throw StudioError.invalid("用户接受记录不属于当前候选或端点，续段保持等待。")
        }
        let risks = review.knownVisualRisks ?? []
        guard risks.count <= 20,risks.allSatisfy({ (1...1000).contains($0.utf8.count) }) else { throw StudioError.invalid("视觉风险摘要无效。") }
        if review.provenance?.declaresProductAcceptance == true {
            guard review.actionRevisionNumber == job.actionRevisionNumber,
                  review.acceptancePromptSHA256 == (job.h3FirstProposal?.promptSHA256 ?? job.h3QueuePlan!.promptSHA256),
                  review.acceptanceStaticBindingSHA256 == job.h3StaticBinding?.recordSHA256 else { throw StudioError.invalid("界面接受记录属于旧输入或修订。") }
        }
        let authenticated = try (review.status == "pass" && (review.selectedWindowViewed && review.endpointPixelsViewed || review.provenance?.declaresProductAcceptance == true)
            && H3AcceptanceAuthority.valid(review,workspace:workspace,runtime:runtime))
        return .init(status:authenticated ? "accepted" : "unattributed",receiptPath:url.path,receiptSHA256:H3ABConfigurationReader.digest(bytes),clipSHA256:review.clipSHA256,
            endpointPath:expected.1,endpointSHA256:review.endpointSHA256,endpointRawIndex:review.endpointRawIndex,
            selectedRawHalfOpen:review.selectedRawHalfOpen,evidenceID:review.userEvidenceID,reviewedAt:review.reviewedAt,
            knownVisualRisks:risks,observation:review.observation,provenance:review.provenance ?? (runtime.mode == .mock ? .fixture : nil))
    }
    static func accept(job: ShotJob,workspace: URL,runtime: H3Runtime,risks: [String],continueNext: Bool = true,successor: ShotJob? = nil) throws -> H3VideoReviewState {
        if let existing = try load(job:job,workspace:workspace,runtime:runtime),existing.isTrustedAcceptance,
           !continueNext || successor == nil || existing.canAuthorizeContinuation &&
            (existing.provenance?.declaresProductAcceptance != true || existing.provenance?.successorAppJobID == successor?.id) { return existing }
        var review = try evidence(job:job,workspace:workspace,runtime:runtime).0
        review.userEvidenceID = runtime.mode == .mock ? "CPU-user-acceptance-fixture" : "AppUI_" + UUID().uuidString
        review.acceptanceSource = runtime.mode == .mock ? "cpu_fixture" : "app_ui_actor_unknown";review.knownVisualRisks = risks
        if runtime.mode == .real { try recordUIAction(&review,job:job,workspace:workspace,continueNext:continueNext,successor:successor) }
        let url = H3QueueExecution.reviewURL(workspace:workspace,id:job.id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        if FileManager.default.fileExists(atPath:url.path) {
            let previous = try H3Files.read(url,limit:16384),history = url.deletingLastPathComponent().appendingPathComponent("receipt-history/" + H3ABConfigurationReader.digest(previous) + ".json")
            try FileManager.default.createDirectory(at:history.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:history.path) { try previous.write(to:history,options:.withoutOverwriting) }
        }
        try encoder.encode(review).write(to:url,options:.atomic)
        return try load(job:job,workspace:workspace,runtime:runtime)!
    }
    /// Import an explicit external instruction, preserving any older UI-only
    /// receipt. Neither a display name nor an AppUI UUID establishes a person.
    static func importUserInstruction(_ source: URL,job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3VideoReviewState {
        let bytes = try H3Files.read(H3Files.safe(source.path),limit:32768)
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let instruction = try decoder.decode(H3UserVideoAcceptanceInstruction.self,from:bytes)
        var review = try evidence(job:job,workspace:workspace,runtime:runtime).0
        try instruction.validate(against:review)
        let hash = H3ABConfigurationReader.digest(bytes)
        let directory = workspace.appendingPathComponent("h3-queue-reviews/" + job.id.uuidString)
        let frozen = directory.appendingPathComponent("acceptance-instructions/" + hash + "/source.json")
        try FileManager.default.createDirectory(at:frozen.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:frozen.path) {
            guard try H3Files.read(frozen,limit:32768) == bytes else { throw StudioError.invalid("已保存接受指令发生变化。") }
        } else { try bytes.write(to:frozen,options:.withoutOverwriting) }
        review.status = "pass";review.reviewerKind = instruction.actorKind;review.userEvidenceID = "Instruction_" + hash
        review.acceptanceSource = "external_user_instruction";review.selectedWindowViewed = instruction.selectedWindowViewed
        review.endpointPixelsViewed = instruction.endpointPixelsViewed;review.observation = instruction.observation
        review.knownVisualRisks = instruction.knownVisualRisks;review.reviewedAt = instruction.instructedAt
        review.provenance = .init(origin:"external_user_instruction",actorKind:instruction.actorKind,
            sourceReference:instruction.sourceReference,instructionPath:frozen.path,instructionSHA256:hash,continuationAuthorized:instruction.authorizeContinuation == true)
        let target = H3QueueExecution.reviewURL(workspace:workspace,id:job.id)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let encoded = try encoder.encode(review)
        if FileManager.default.fileExists(atPath:target.path) {
            let previous = try H3Files.read(target,limit:16384)
            if previous != encoded {
                let history = directory.appendingPathComponent("receipt-history/" + H3ABConfigurationReader.digest(previous) + ".json")
                try FileManager.default.createDirectory(at:history.deletingLastPathComponent(),withIntermediateDirectories:true)
                if !FileManager.default.fileExists(atPath:history.path) { try previous.write(to:history,options:.withoutOverwriting) }
            }
        }
        try encoded.write(to:target,options:.atomic)
        return try load(job:job,workspace:workspace,runtime:runtime)!
    }
}

extension TaskStore {
    func currentPlannedJob(_ request: String) -> ShotJob? {
        state.jobs.first(where:{ $0.h3QueuePlan?.requestID == request && $0.supersededBy == nil })
    }
    func canAcceptVideo(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.status == .completed,job.supersededBy == nil,
              job.h3QueuePlan != nil,job.externalHistory == nil,job.h3VideoRejection == nil,job.h3Outcome?.technicalPass == true,job.h3Binding?.appTaskID == id else { return false }
        return !FileManager.default.fileExists(atPath:H3VideoRejectionReader.url(workspace:root,id:id).path)
    }
    func acceptVideoAndContinue(_ id: UUID,continueNext: Bool = true) async {
        guard canAcceptVideo(id),let job = state.jobs.first(where:{ $0.id == id }) else { return }
        let workspace = root,runtime = h3Runtime
        let successor = state.jobs.first(where:{ $0.supersededBy == nil && $0.h3QueuePlan?.dependencyRequestID == job.h3QueuePlan!.requestID })
        configurationReadOperation = "绑定用户接受的 \(job.shortID) 第\(job.h3QueuePlan!.part)段与精确端帧";abConfigurationBusy = true
        do {
            let review = try await Task.detached(priority:.utility) {
                try H3VideoReviewReader.accept(job:job,workspace:workspace,runtime:runtime,risks:job.h3VideoReview?.knownVisualRisks ?? [],continueNext:continueNext,successor:successor)
            }.value
            guard !shuttingDown,let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status == .completed,state.jobs[index].supersededBy == nil else { abConfigurationBusy = false;return }
            state.jobs[index].h3VideoReview = review;persist();abConfigurationBusy = false
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            if continueNext,review.canAuthorizeContinuation,let next = state.jobs.first(where:{ $0.supersededBy == nil && $0.h3QueuePlan?.dependencyRequestID == job.h3QueuePlan!.requestID }) {
                selectedID = next.id;await startPlannedJob(next.id)
            } else { notice = review.isTrustedAcceptance ? "本段接受已记录，候选与操作来源保留。" : "旧记录缺少明确接受动作；可在应用中接受当前候选。" }
        } catch { abConfigurationBusy = false;notice = error.localizedDescription }
    }
    func refreshQueueVideoReviews() async {
        guard !videoReviewRefreshInFlight,singleGeneratorIdle else { return }
        let jobs = state.jobs.filter { $0.supersededBy == nil && $0.status == .completed && $0.externalHistory == nil && $0.h3QueuePlan != nil && $0.h3VideoReview?.isTrustedAcceptance != true }
        guard !jobs.isEmpty else { return }
        videoReviewRefreshInFlight = true;defer { videoReviewRefreshInFlight = false }
        let workspace = root,runtime = h3Runtime
        let results = await Task.detached(priority:.utility) {
            jobs.compactMap { job -> (UUID,H3VideoReviewState)? in
                guard let review = try? H3VideoReviewReader.load(job:job,workspace:workspace,runtime:runtime) else { return nil }
                return (job.id,review)
            }
        }.value
        guard !shuttingDown else { return }
        var changed = false
        for (id,review) in results {
            if let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].status == .completed,state.jobs[i].supersededBy == nil,state.jobs[i].h3VideoReview != review {
                state.jobs[i].h3VideoReview = review;changed = true
            }
        }
        if changed { persist() }
    }
    func importUserVideoAcceptance(_ url: URL,id: UUID) async throws {
        guard canAcceptVideo(id),let job = state.jobs.first(where:{ $0.id == id }) else { throw StudioError.invalid("当前任务不能绑定视频接受指令。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let workspace = root,runtime = h3Runtime
        let review = try await Task.detached(priority:.utility) {
            try H3VideoReviewReader.importUserInstruction(url,job:job,workspace:workspace,runtime:runtime)
        }.value
        guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].supersededBy == nil,
              state.jobs[i].h3Binding == job.h3Binding else { throw StudioError.invalid("任务已改变，接受指令未接续。") }
        state.jobs[i].h3VideoReview = review;persist()
        guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "外部用户接受已记录，来源与风险保留；没有自动启动下一段。"
    }
    func canRedoVideo(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.supersededBy == nil,
              [.completed,.failed,.cancelled,.interrupted].contains(job.status),job.externalHistory == nil,
              let plan = job.h3QueuePlan,job.h3Binding != nil,
              state.jobs.count + plan.partCount-plan.part+1 <= 2000 else { return false }
        return true
    }
    /// Explicit redo creates a new App execution identity and keeps old rows,
    /// candidates and receipts. Only unclaimed bound dependents are invalidated.
    func redoVideo(_ id: UUID) async {
        guard canRedoVideo(id),let index = state.jobs.firstIndex(where:{ $0.id == id }),let plan = state.jobs[index].h3QueuePlan else { return }
        let originals = [state.jobs[index]] + state.jobs.filter { $0.supersededBy == nil && $0.h3QueuePlan?.shot == plan.shot &&
            ($0.h3QueuePlan?.part ?? 0) > plan.part && ($0.h3FirstProposal != nil || !$0.attempts.isEmpty || $0.h3Binding != nil) }
        let before = state,selection = selectedID
        var updated = state
        var replacements: [ShotJob] = []
        for old in originals {
            var next = ShotJob(shot:old.shot,segment:old.segment,title:old.title + " · 重做",prompt:old.prompt,
                reference:old.h3QueuePlan!.identityReferencePath,requestedDuration:old.requestedDuration,engine:.h3,status:.blocked)
            next.h3QueuePlan = old.h3QueuePlan;next.parameters = old.parameters;next.parameters.verified = false;next.redoOf = old.id
            next.requiresNewStaticInput = old.h3StaticBinding != nil || old.h3FirstProposal?.queueExecution?.actionRevision != nil
            next.importKey = "redo:" + next.id.uuidString;next.stage = "重做已登记 · 原候选与历史保留"
            next.logTail.append("App 重做操作：原任务 \(old.id.uuidString)、拒绝与接受回执保留；未由界面来源认定操作者为用户。后续不会再采用原端帧。")
            if next.requiresNewStaticInput == true { next.stage = "修订候选重做 · 绑定完整静态首图后重新检查提示词" }
            if let i = updated.jobs.firstIndex(where:{ $0.id == old.id }) {
                updated.jobs[i].supersededBy = next.id
                if updated.jobs[i].status.isPending {
                    let now = Date()
                    updated.jobs[i].status = .cancelled;updated.jobs[i].stage = "重做前段 · 原端帧绑定已失效"
                    updated.jobs[i].endedAt = now;updated.jobs[i].progress = nil
                    updated.jobs[i].h3AutomaticWorkflow?.status = "cancelled"
                    updated.jobs[i].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
                    updated.jobs[i].h3AutomaticWorkflow?.endedAt = now
                    let stage = updated.jobs[i].stage
                    updated.jobs[i].executionActivity?.finish(.cancelled,stage:stage,at:now)
                }
                updated.jobs[i].h3VideoReview?.status = "superseded"
            }
            replacements.append(next)
        }
        updated.jobs.append(contentsOf:replacements);state = updated;selectedID = replacements.first?.id;persist()
        guard storageFault == nil,let next = replacements.first else { state = before;selectedID = selection;return }
        await startPlannedJob(next.id)
    }
}
