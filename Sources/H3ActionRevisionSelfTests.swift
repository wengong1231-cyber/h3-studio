import Foundation

@MainActor enum H3ActionRevisionSelfTests {
    struct Context { var store: TaskStore;var id: UUID;var request: URL }
    static func environment(root: URL,executable: URL) async throws -> Context {
        let env = try await H3FirstSelfTests.environment(root:root,executable:executable)
        let manifest = try H3QueueExecutionSelfTests.fixtureManifest(env,root:root)
        _ = try await env.store.importPlannedQueue(manifest)
        let id = env.store.state.jobs.first(where:{ $0.h3QueuePlan?.shot == 35 && $0.h3QueuePlan?.part == 1 })!.id
        await env.store.startPlannedJob(id,mockScenario:"slow_generation")
        guard env.store.state.jobs.first(where:{ $0.id == id })?.h3FirstProposal?.input != nil else {
            throw StudioError.invalid(env.store.state.jobs.first(where:{ $0.id == id })?.error ?? "fixture input missing")
        }
        try H3FirstSelfTests.review(env.store,id:id,status:"fail");await env.store.checkFirstPixelReviews()
        let request = try makeRequest(store:env.store,id:id,root:root)
        return .init(store:env.store,id:id,request:request)
    }
    static func makeRequest(store: TaskStore,id: UUID,root: URL) throws -> URL {
        let job = store.state.jobs.first(where:{ $0.id == id })!,p = job.h3FirstProposal!,plan = job.h3QueuePlan!,input = p.input!
        let prompt = "CPU fixture revision: separate airborne chariots maintain their own original opposite directions, all subjects remain fully framed. This is protocol evidence, not semantic QA.\n"
        let draft = root.appendingPathComponent("airborne-r2.txt");try Data(prompt.utf8).write(to:draft)
        let object: [String:Any] = ["schema":"jingsheng-assistant-action-revision-handoff-v1","status":"draft_for_App_developer_not_a_runtime_supported_request",
            "appJobID":id.uuidString,"requestID":plan.requestID,"shot":p.shot,"part":p.part,
            "baseline":["status":"failed","attempts":0,"manifestSnapshotPath":plan.manifestSnapshotPath!,"manifestSHA256":plan.manifestSHA256,
                "proposalPath":p.sourcePath,"proposalSHA256":p.sourceSHA256,"promptPath":p.promptPath,"promptSHA256":p.promptSHA256,
                "failureReviewPath":store.firstReviewURL(id).path,"failureReviewSHA256":try WorkspaceDigest.sha256(store.firstReviewURL(id))],
            "requestedRevision":["actionGoal":"CPU fixture: opposite directions, airborne motion and complete framing.","promptUTF8":prompt,
                "promptDraftPath":draft.path,"promptSHA256":H3ABConfigurationReader.digest(Data(prompt.utf8)),"promptOnlyRevisionOfSameTask":true],
            "frozenInputs":["sourceMediaPath":p.sourceMediaPath,"sourceMediaSHA256":p.sourceMediaSHA256,"sourceFrameIndex":p.sourceFrameIndex,
                "originalPath":input.originalPath,"originalSHA256":input.originalSHA256,"normalizedPath":input.normalizedPath,"normalizedSHA256":input.normalizedSHA256,
                "profile":try JSONSerialization.jsonObject(with:JSONEncoder().encode(p.profile)),"selectedRawHalfOpen":[p.selectedRawStart,p.selectedRawEnd],
                "destinationGlobalHalfOpen":[p.destinationGlobalStart,p.destinationGlobalEnd],"seed":p.seed]]
        let url = root.appendingPathComponent("revision-handoff.json")
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url)
        return url
    }
    static func digest(_ job: ShotJob) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return H3ABConfigurationReader.digest(try encoder.encode(job))
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            func normalFlow() async throws -> (URL,H3Runtime,UUID,UUID,H3VideoRejectionState) {
            let env = try await environment(root:root.appendingPathComponent("normal"),executable:executable),store = env.store,id = env.id
            let old = store.state.jobs.first(where:{ $0.id == id })!,oldProposal = old.h3FirstProposal!,oldInput = oldProposal.input!,oldReviewURL = store.firstReviewURL(id)
            let oldReviewBytes = try H3Files.read(oldReviewURL),oldDescriptor = try H3Files.read(H3Files.safe(oldProposal.sourcePath))
            let otherHashes = try store.state.jobs.filter { $0.id != id }.map { try digest($0) }
            try check("失败图审未领取",old.status == .failed && old.attempts.isEmpty && old.h3Binding == nil && oldProposal.pixelReview?.status == "fail" && store.launchCount == 0,"real CPU previews, failed fixture QA, no native claim")
            var bad = try JSONSerialization.jsonObject(with:H3Files.read(env.request)) as! [String:Any]
            bad["appJobID"] = UUID().uuidString
            let wrong = env.request.deletingLastPathComponent().appendingPathComponent("wrong.json")
            try JSONSerialization.data(withJSONObject:bad).write(to:wrong)
            await store.reviseAction(id,requestURL:wrong)
            try check("错身份不改变失败任务",try digest(store.state.jobs.first(where:{ $0.id == id })!) == digest(old),"no state edit, overwrite or claim")
            bad = try JSONSerialization.jsonObject(with:H3Files.read(env.request)) as! [String:Any]
            var frozen = bad["frozenInputs"] as! [String:Any];frozen["seed"] = oldProposal.seed + 1;bad["frozenInputs"] = frozen
            try JSONSerialization.data(withJSONObject:bad).write(to:wrong);await store.reviseAction(id,requestURL:wrong)
            try check("动作修订不能改种子",try digest(store.state.jobs.first(where:{ $0.id == id })!) == digest(old),"source/index/profile/window/seed remain frozen")
            let cancelledControl = H3PreparationControl();cancelledControl.cancel()
            var cancelledBeforeCommit = false
            do { _ = try H3ActionRevision.prepare(job:old,requestURL:env.request,reviewURL:oldReviewURL,workspace:store.root,runtime:store.h3Runtime,control:cancelledControl) }
            catch is H3PreprocessingCancelled { cancelledBeforeCommit = true }
            try check("提交前取消保留原失败",cancelledBeforeCommit && (try digest(store.state.jobs.first(where:{ $0.id == id })!)) == (try digest(old)),"cancelled staging does not activate revision")
            // Simulate a crash after immutable files were staged but before the
            // task state was committed. Reapplying uses identical frozen files.
            let staged = try H3ActionRevision.prepare(job:old,requestURL:env.request,reviewURL:oldReviewURL,workspace:store.root,runtime:store.h3Runtime,control:H3PreparationControl())
            try check("暂存不修改工作区任务",try digest(store.state.jobs.first(where:{ $0.id == id })!) == digest(old),"staged revision can be reviewed without activation")
            let first = Task { await store.reviseAction(id,requestURL:env.request) }
            await Task.yield();await store.reviseAction(id,requestURL:env.request);await first.value
            guard let revised = store.state.jobs.first(where:{ $0.id == id }),let proposal = revised.h3FirstProposal,
                  let revision = proposal.queueExecution?.actionRevision,let input = proposal.input else {
                throw StudioError.invalid(store.notice ?? "revision preparation missing")
            }
            try check("相同UUID和条数",revised.id == id && store.state.jobs.count == 33 && revised.h3QueuePlan == old.h3QueuePlan,"immutable base manifest unchanged, same task row")
            try check("其他32段原样保留",try store.state.jobs.filter { $0.id != id }.map { try digest($0) } == otherHashes,"S19p02/S35p02 and all other state untouched")
            try check("暂存恢复与重复点击安全",revision == staged.queueExecution?.actionRevision && revision.number == 2 && store.launchCount == 0,"one revision, fresh QA required, no native or duplicated input activation")
            try check("旧提案和失败QA未覆盖",try H3Files.read(H3Files.safe(oldProposal.sourcePath)) == oldDescriptor && H3Files.read(oldReviewURL) == oldReviewBytes,"original files remain byte-identical")
            try check("旧失败历史持久化",try H3Files.read(H3Files.safe(revision.directory + "/previous-pixel-review.json")) == oldReviewBytes,"full failed task, old prompt, descriptor and review retained")
            try check("新提示词新提案身份",proposal.promptSHA256 != oldProposal.promptSHA256 && proposal.sourceSHA256 != oldProposal.sourceSHA256 && revised.prompt == proposal.prompt,"revision overlay is bound in new descriptor and actual UI prompt")
            try check("实际源帧重新准备",input.originalSHA256 == oldInput.originalSHA256 && input.normalizedSHA256 == oldInput.normalizedSHA256 && input.originalPath != oldInput.originalPath && revised.h3InputPreparation?.images.count == 2,"CPU exact re-extraction at same index, no replacing old PNG or inherited QA")
            try check("全参数冻结",proposal.sourceMediaSHA256 == oldProposal.sourceMediaSHA256 && proposal.sourceFrameIndex == oldProposal.sourceFrameIndex && proposal.profile == oldProposal.profile && proposal.seed == oldProposal.seed && proposal.selectedRawEnd == oldProposal.selectedRawEnd,"same input/source,73 native frames,[0,68),same seed")
            try oldReviewBytes.write(to:store.firstReviewURL(id));await store.checkFirstPixelReviews()
            try check("旧QA不能放行新修订",store.launchCount == 0 && store.state.jobs.first(where:{ $0.id == id })!.h3FirstProposal?.pixelReview == nil && store.state.jobs.first(where:{ $0.id == id })!.status.isPending,"same image hashes cannot bypass changed proposal and prompt bindings")
            try H3FirstSelfTests.review(store,id:id);await store.checkFirstPixelReviews()
            try check("新QA自动领取一次",store.launchCount == 1 && store.activeJob?.id == id && !store.canReviseAction(id),"current input QA bound, existing attempt-once and max concurrency1 retained")
            await store.reviseAction(id,requestURL:env.request);await store.startAuthorizedFirst(id);await store.checkFirstPixelReviews()
            try check("运行中禁止修订与重复领取",store.launchCount == 1 && store.activeJob?.id == id,"running attempt remains immutable")
            try await StudioSelfTests.wait("revision CPU native73",timeout:40) { store.activeJob == nil }
            let completed = store.state.jobs.first(where:{ $0.id == id })!
            try check("修订后73帧严格技术通过",completed.status == .completed && completed.h3Outcome?.technicalPass == true && completed.h3Outcome?.simulated == true,"actual CPU MP4 and lossless frames, no real model invocation")
            try check("修订历史进入冻结链",completed.h3Binding?.appFirstTask?.proposal.queueExecution?.actionRevision == revision && store.launchCount == 1,"SHA-bound manifest and revision histories remain validated")
            try check("r2完成候选可独立拒绝与重做",store.canRejectVideo(id) && store.canRedoVideo(id),"revision overlay no longer disables terminal candidate actions")
            try H3QueueExecutionSelfTests.endpointReview(store:store,id:id)
            let acceptanceURL = H3QueueExecution.reviewURL(workspace:store.root,id:id),acceptedBytes = try H3Files.read(acceptanceURL)
            let candidate = completed.candidate!,candidateSHA = try WorkspaceDigest.sha256(H3Files.safe(candidate))
            let following = store.currentPlannedJob("planned-S35-p02-20261006")!.id
            await store.startPlannedJob(following)
            guard let childProposal = store.state.jobs.first(where:{ $0.id == following })!.h3FirstProposal else { throw StudioError.invalid("revision continuation preparation missing") }
            try await store.rejectVideo(id,reason:"CPU protocol fixture rejection: candidate detail is unacceptable; no real semantic assessment.")
            let rejected = store.state.jobs.first(where:{ $0.id == id })!.h3VideoRejection!
            try check("界面拒绝不冒认用户",rejected.actorKind == "unknown" && rejected.record.origin == "app_ui" && !store.canAcceptVideo(id),"separate rejection receipt; original acceptance remains historical evidence")
            let receiptBytes = try H3Files.read(H3Files.safe(rejected.receiptPath))
            try await store.rejectVideo(id,reason:"CPU repeated UI click fixture; do not duplicate decisions.")
            let repeatedBytes = try H3Files.read(H3Files.safe(rejected.receiptPath))
            try check("重复拒绝幂等",receiptBytes == repeatedBytes && store.launchCount == 1,"same candidate keeps one decision and no native retry")
            try H3FirstSelfTests.review(store,id:following);await store.checkFirstPixelReviews()
            var rejectedEndpoint = false
            do { _ = try H3QueueExecution.parse(H3Files.read(H3Files.safe(childProposal.snapshotPath!)),sourcePath:childProposal.sourcePath,runtime:store.h3Runtime) } catch { rejectedEndpoint = true }
            try check("拒绝覆盖旧接受并阻塞已备旧QA",rejectedEndpoint && !store.canPreparePlannedJob(following) && store.launchCount == 1 && !store.state.jobs.first(where:{ $0.id == id })!.videoContinuationAuthorized,"both dispatcher state and fresh native descriptor checks reject the old endpoint")
            let identity = rejected.record.candidate
            let source = env.request.deletingLastPathComponent().appendingPathComponent("external-rejection.json")
            let instruction: [String:Any] = ["schema":"S35p01-r2-user-rejection-v1","appJobID":id.uuidString,"actionRevision":2,
                "outputSHA256":identity.clipSHA256,"decision":"rejected_by_user; CPU protocol fixture, not an actual user statement",
                "exactUserQuote":"CPU protocol fixture: rejected details; this test does not assert a real user decision.",
                "userReplyID":"CPU-fixture-explicit-source","sourceThreadID":"CPU-fixture-source-thread","recordedAtUTC":"2026-10-07T00:51:51.685236Z"]
            try JSONSerialization.data(withJSONObject:instruction,options:[.sortedKeys]).write(to:source)
            try await store.rejectVideo(id,reason:"",source:source)
            let external = store.state.jobs.first(where:{ $0.id == id })!.h3VideoRejection!
            try check("外部拒绝保留来源与r2实际输出",external.actorKind == "user" && external.record.candidate == identity && external.sourceReference.contains("CPU-fixture-explicit-source") && external.record.instructionSHA256 != nil,"supported parent handoff schema is frozen; fixture attribution is not real acceptance")
            var mismatch = instruction;mismatch["outputSHA256"] = String(repeating:"0",count:64)
            let wrongRejection = source.deletingLastPathComponent().appendingPathComponent("wrong-rejection.json")
            try JSONSerialization.data(withJSONObject:mismatch).write(to:wrongRejection)
            var wrongRejected = false;do { try await store.rejectVideo(id,reason:"",source:wrongRejection) } catch { wrongRejected = true }
            try check("错输出拒绝指令不覆盖",wrongRejected && store.state.jobs.first(where:{ $0.id == id })!.h3VideoRejection == external,"exact candidate, revision and source binding required")
            await store.redoVideo(id)
            let replacement = store.currentPlannedJob("planned-S35-p01-20261006")!
            let oldOutputSHA = try WorkspaceDigest.sha256(H3Files.safe(candidate)),preservedAcceptance = try H3Files.read(acceptanceURL)
            try check("r2重做保留候选与冻结旧来源",replacement.id != id && replacement.redoOf == id && oldOutputSHA == candidateSHA && preservedAcceptance == acceptedBytes,"original native clip, rejection and acceptance files remain intact")
            try check("r2重做须绑定实际新首图",replacement.requiresNewStaticInput == true && replacement.h3FirstProposal == nil && replacement.prompt == proposal.prompt && !store.canPreparePlannedJob(replacement.id) && store.launchCount == 1,"no fallback to original manifest prompt or contradictory old identity reference")
            let redoCount = store.state.jobs.count;await store.redoVideo(id)
            try check("r2重做重复点击不叠任务",store.state.jobs.count == redoCount && !store.canRedoVideo(id),"old App ID superseded; child endpoint also invalidated")
            store.shutdown()
            return (store.root,store.h3Runtime,id,replacement.id,external)
            }
            // The previous owner must leave scope before reopening its lock;
            // shutdown alone intentionally does not permit two live owners.
            let normal = try await normalFlow()
            let rejectionRestored = try TaskStore(root:normal.0,executable:executable,monitoring:false,h3Runtime:normal.1)
            let restoredRejection = rejectionRestored.state.jobs.first(where:{ $0.id == normal.2 })!.h3VideoRejection
            let frozenRejection = try H3VideoRejectionReader.read(workspace:rejectionRestored.root,id:normal.2)
            try check("拒绝与重做依赖重启后保留",restoredRejection == normal.4 && frozenRejection == normal.4 && !rejectionRestored.canPreparePlannedJob(normal.3) && rejectionRestored.launchCount == 0,"actual Workspace reopen; no receipt or acceptance resurrection, no native replay")
            rejectionRestored.shutdown()

            let cancelled = try await environment(root:root.appendingPathComponent("cancel"),executable:executable)
            let cancelTask = Task { await cancelled.store.reviseAction(cancelled.id,requestURL:cancelled.request) }
            try await StudioSelfTests.wait("revision staging ownership",timeout:5) { cancelled.store.actionRevisionID == cancelled.id || cancelled.store.abPreparationID == cancelled.id }
            cancelled.store.cancel(cancelled.id,source:"CPU revision cancellation test");await cancelTask.value
            try check("取消修订不启动GPU",cancelled.store.launchCount == 0 && [.failed,.cancelled].contains(cancelled.store.state.jobs.first(where:{ $0.id == cancelled.id })!.status),"cancel before commit keeps failure; cancel during preparation keeps staged history")
            cancelled.store.shutdown()

            func prepareRecovery() async throws -> (URL,H3Runtime,UUID) {
                let recoveredEnv = try await environment(root:root.appendingPathComponent("recovery"),executable:executable)
                await recoveredEnv.store.reviseAction(recoveredEnv.id,requestURL:recoveredEnv.request)
                guard recoveredEnv.store.state.jobs.first(where:{ $0.id == recoveredEnv.id })!.h3FirstProposal?.input != nil else { throw StudioError.invalid("recovery preparation missing") }
                recoveredEnv.store.shutdown();return (recoveredEnv.store.root,recoveredEnv.store.h3Runtime,recoveredEnv.id)
            }
            let context = try await prepareRecovery(),restored = try TaskStore(root:context.0,executable:executable,monitoring:false,h3Runtime:context.1)
            let restoredJob = restored.state.jobs.first(where:{ $0.id == context.2 })!
            try check("修订待检查重启恢复",restoredJob.id == context.2 && restoredJob.h3FirstProposal?.queueExecution?.actionRevision?.number == 2 && restoredJob.h3AutomaticWorkflow?.phase == "pixel_qa" && restored.launchCount == 0,"persisted revision/input, no native replay")
            restored.cancel(context.2,source:"CPU cancel after restart");try H3FirstSelfTests.review(restored,id:context.2);await restored.checkFirstPixelReviews()
            try check("取消后迟到新QA不启动",restored.launchCount == 0 && restored.state.jobs.first(where:{ $0.id == context.2 })!.status == .cancelled,"completed preparation and revision history retained")
            restored.shutdown()
            checks += try await H3RejectionScopeSelfTests.run(root:root.appendingPathComponent("review-scope"),executable:executable)
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
