import Foundation

@MainActor enum H3VideoReviewSelfTests {
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let env = try await H3FirstSelfTests.environment(root:root,executable:executable),store = env.store
            _ = try await store.importPlannedQueue(H3QueueExecutionSelfTests.fixtureManifest(env,root:root))
            let p1 = env.id,p2 = store.currentPlannedJob("planned-S19-p02-20261006")!.id
            try check("未完成视频不能接受",!store.canAcceptVideo(p1),"technical pass required; input QA is not video acceptance")
            await store.startAuthorizedFirst(p1);try H3FirstSelfTests.review(store,id:p1);await store.checkFirstPixelReviews()
            try check("运行期间禁改依赖",!store.canAcceptVideo(p1) && !store.canRedoVideo(p1),"max concurrency1 and active chain protected")
            try await StudioSelfTests.wait("video acceptance CPU native90",timeout:40) { store.activeJob == nil }
            let before = store.activity(for:store.state.jobs.first(where:{ $0.id == p2 })!)
            try check("续段具体等待应用内接受",before.state == "等待前段候选接受" && before.nextStep!.contains("无需聊天"),"technical pass is not content acceptance; no per-image operator step")
            let completed = store.state.jobs.first(where:{ $0.id == p1 })!,successor = store.state.jobs.first(where:{ $0.id == p2 })!
            var uiReview = try H3VideoReviewReader.evidence(job:completed,workspace:store.root,runtime:store.h3Runtime).0
            try H3VideoReviewReader.recordUIAction(&uiReview,job:completed,workspace:store.root,continueNext:true,successor:successor)
            let uiURL = H3QueueExecution.reviewURL(workspace:store.root,id:p1),uiEncoder = JSONEncoder();uiEncoder.dateEncodingStrategy = .iso8601
            try uiEncoder.encode(uiReview).write(to:uiURL,options:.withoutOverwriting)
            let uiAccepted = try H3VideoReviewReader.load(job:completed,workspace:store.root,runtime:store.h3Runtime)!
            try check("应用接受有效而操作者不冒认",uiAccepted.isTrustedAcceptance && uiAccepted.canAuthorizeContinuation && uiAccepted.provenance?.actorKind == "unknown" && !uiReview.selectedWindowViewed && !uiReview.endpointPixelsViewed,"explicit product action is distinct from independently verified viewing or user identity")
            try check("实际事件文件绑定当前续段",try H3AcceptanceAuthority.valid(uiReview,workspace:store.root,runtime:.real,requireContinuation:true,successorAppJobID:p2,successorRequestID:successor.h3QueuePlan!.requestID),"checks real frozen event bytes; no real H3 process")
            try check("应用接受不能放行另一版续段",try !H3AcceptanceAuthority.valid(uiReview,workspace:store.root,runtime:.real,requireContinuation:true,successorAppJobID:UUID(),successorRequestID:successor.h3QueuePlan!.requestID),"redo UUID cannot inherit prior product action")
            let uiBytes = try H3Files.read(uiURL)
            let sameAction = try H3VideoReviewReader.accept(job:completed,workspace:store.root,runtime:store.h3Runtime,risks:[],continueNext:true,successor:successor)
            try check("应用重复接受复用原事件",sameAction == uiAccepted && H3Files.read(uiURL) == uiBytes && store.launchCount == 1,"same action does not overwrite receipt or submit GPU")
            var uiMismatch = uiReview;uiMismatch.actionRevisionNumber = 2
            var mismatchRejected = false
            do { _ = try H3AcceptanceAuthority.valid(uiMismatch,workspace:store.root,runtime:.real) } catch { mismatchRejected = true }
            try check("旧修订事件不能接受新版本",mismatchRejected,"revision and prompt bind the immutable UI event")
            // Continue the independent external-receipt regression with its
            // existing CPU fixture; no production receipt is modified.
            // Existing external user acceptance receipts are synchronized into
            // App state; known risks stay visible after acceptance.
            try H3QueueExecutionSelfTests.endpointReview(store:store,id:p1,cacheState:false)
            let url = H3QueueExecution.reviewURL(workspace:store.root,id:p1)
            var object = try JSONSerialization.jsonObject(with:H3Files.read(url)) as! [String:Any]
            object["knownVisualRisks"] = ["走位偏离（CPU上下文夹具）","背部武器变淡（CPU上下文夹具）"]
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)
            await store.refreshQueueVideoReviews()
            let accepted = store.state.jobs.first(where:{ $0.id == p1 })!.h3VideoReview!
            try check("聊天接受同步并保留两条风险",accepted.status == "accepted" && accepted.knownVisualRisks.count == 2 && store.launchCount == 1,"actual fixture receipt bound to exact clip, report, job and raw83 endpoint")
            let ready = store.activity(for:store.state.jobs.first(where:{ $0.id == p2 })!)
            try check("接受后等待状态变为可接续",ready.state == "首段已接受 · 可以准备续段" && ready.detail.contains("raw83"),"no redundant user acceptance click after matching receipt")
            let receiptBytes = try H3Files.read(url)
            await store.acceptVideoAndContinue(p1,continueNext:false);await store.acceptVideoAndContinue(p1,continueNext:false)
            try check("重复接受幂等",try H3Files.read(url) == receiptBytes && store.launchCount == 1,"same accepted output retains its original evidence without overwrite")
            await store.acceptVideoAndContinue(p1)
            let next = store.state.jobs.first(where:{ $0.id == p2 })!
            try check("接受并继续只准备下一段",next.h3FirstProposal?.input?.exactFrameIndex == 83 && next.h3AutomaticWorkflow?.phase == "pixel_qa" && store.launchCount == 1,"assistant checks actual prepared input; no extra image approval button")
            await store.acceptVideoAndContinue(p1)
            try check("继续双击不重复准备",store.launchCount == 1 && store.state.jobs.first(where:{ $0.id == p2 })!.h3FirstProposal == next.h3FirstProposal,"same task, input and review gate")
            let oldCandidate = store.state.jobs.first(where:{ $0.id == p1 })!.candidate!,oldHash = try WorkspaceDigest.sha256(H3Files.safe(oldCandidate))
            await store.redoVideo(p1)
            guard let replacement = store.currentPlannedJob("planned-S19-p01-20261006"),let replacement2 = store.currentPlannedJob("planned-S19-p02-20261006") else { throw StudioError.invalid("redo identities missing") }
            try check("重做独立身份保留历史",replacement.id != p1 && replacement.redoOf == p1 && store.state.jobs.first(where:{ $0.id == p1 })!.supersededBy == replacement.id,"old candidate and native claim stay immutable, original plan retained")
            try check("原接受不再放行依赖",replacement.h3VideoReview == nil && !store.canPreparePlannedJob(replacement2.id) && replacement2.id != p2,"old accepted endpoint cannot release new chain")
            try check("已备旧续段取消不丢图",store.state.jobs.first(where:{ $0.id == p2 })!.status == .cancelled && store.state.jobs.first(where:{ $0.id == p2 })!.h3FirstProposal?.input != nil,"old QA and images retained as superseded history")
            await store.redoVideo(p1);try H3FirstSelfTests.review(store,id:p2);await store.checkFirstPixelReviews()
            try check("重做双击与旧QA不投递",store.state.jobs.count == 35 && store.launchCount == 1,"one redo chain, no duplicate native run or late old-QA release")
            try check("旧候选字节保留",try WorkspaceDigest.sha256(H3Files.safe(oldCandidate)) == oldHash && H3Files.read(url) == receiptBytes,"no clip, endpoint or accepted receipt deletion")
            let count = try await store.importPlannedQueue(root.appendingPathComponent("proposals/queue.json"))
            try check("重导清单保持重做身份",count == 0 && store.currentPlannedJob("planned-S19-p01-20261006")!.id == replacement.id,"old rows do not hide the active replacement")
            store.cancel(replacement.id,source:"end CPU video-review fixture");store.shutdown()
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
