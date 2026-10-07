import Foundation

@MainActor enum H3IndependentInputRecoverySelfTests {
    static func run(root: URL,executable: URL) async throws -> [StudioSelfTests.Check] {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ passed: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail))
            print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
            if !passed { throw StudioError.invalid(name) }
        }
        let env = try await H3FirstSelfTests.environment(root:root,executable:executable),store = env.store
        defer { store.shutdown() }
        let manifest = try H3QueueExecutionSelfTests.fixtureManifest(env,root:root)
        var object = try JSONSerialization.jsonObject(with:H3Files.read(manifest)) as! [String:Any]
        var rows = object["items"] as! [[String:Any]]
        let row = rows.firstIndex { $0["shot"] as? Int == 19 }!
        var parts = rows[row]["parts"] as! [[String:Any]]
        // A genuinely independent second source, declared before import and
        // descriptor freezing. The third part still depends on this part.
        parts[1]["first_image"] = parts[0]["first_image"]
        rows[row]["parts"] = parts;object["items"] = rows
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:manifest)
        _ = try await store.importPlannedQueue(manifest)
        let id = store.currentPlannedJob("planned-S19-p02-20261006")!.id
        await store.startAuthorizedFirst(env.id)
        try H3FirstSelfTests.review(store,id:env.id);await store.checkFirstPixelReviews()
        try await StudioSelfTests.wait("independent-recovery CPU parent",timeout:40) { store.activeJob == nil }
        await store.startPlannedJob(id)
        guard let input = store.state.jobs.first(where:{ $0.id == id })?.h3FirstProposal?.input else {
            throw StudioError.invalid("CPU independent source preparation missing")
        }
        try await store.rejectVideo(env.id,reason:"CPU fixture rejection: old scope must not invalidate the independent next source.")
        let index = store.state.jobs.firstIndex { $0.id == id }!
        try check("独立来源真实准备且拒绝不再误阻塞",store.state.jobs[index].h3AutomaticWorkflow?.automaticContinuationAuthorized == true && store.launchCount == 1,"CPU source PNGs and descriptor; no production models or records")
        // Recreate exactly the old persisted bug in the isolated fixture only.
        store.state.jobs[index].stage = H3IndependentInputRecoveryReader.legacyStage
        store.state.jobs[index].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
        let old = store.state.jobs[index]
        func eligible(_ job: ShotJob) -> Bool { H3IndependentInputRecoveryReader.eligible(job,jobs:store.state.jobs) }
        try check("旧误阻塞有专用恢复入口",eligible(old) && store.canRecoverIndependentInput(id),"no dependence on accepted or rejected predecessor pixels")
        var changed = old;changed.status = .cancelled
        try check("取消永不被恢复",!eligible(changed),"explicit cancellation is not a legacy error")
        changed = old;changed.h3QueuePlan?.dependencyRequestID = "planned-S19-p01-20261006"
        changed.h3QueuePlan?.dependencyRawIndex = 83
        try check("真实端点依赖不可恢复",!eligible(changed),"independent recovery cannot bypass acceptance")
        changed = old;changed.stage = "用户暂停或其他阻塞"
        try check("其他阻塞来源不可猜测恢复",!eligible(changed),"requires the exact historical rejection stage")
        changed = old;changed.h3FirstProposal?.queueExecution?.appJobID = UUID()
        try check("错任务身份无恢复入口",!eligible(changed),"descriptor owner must match the same task ID")
        store.fidelityJobID = env.id
        try check("保真实验期间不恢复输入",!store.canRecoverIndependentInput(id),"one global resource gate")
        store.fidelityJobID = nil
        let normalizedURL = URL(fileURLWithPath:input.normalizedPath),normalized = try H3Files.read(normalizedURL)
        try Data("CPU tampered PNG fixture".utf8).write(to:normalizedURL)
        var tamperRejected = false
        do { try await store.recoverIndependentInput(id) } catch { tamperRejected = true }
        try check("归一图篡改不改变任务",tamperRejected && (try H3ActionRevisionSelfTests.digest(store.state.jobs[index])) == (try H3ActionRevisionSelfTests.digest(old)),"no authorization or native claim on fingerprint mismatch")
        try normalized.write(to:normalizedURL)
        try H3FirstSelfTests.review(store,id:id)
        let reviewURL = store.firstReviewURL(id),oldReview = try H3Files.read(reviewURL)
        let others = try store.state.jobs.filter { $0.id != id }.map { try H3ActionRevisionSelfTests.digest($0) }
        let ids = Set(store.state.jobs.map(\.id)),plan = old.h3QueuePlan
        store.pauseQueue()
        try await store.recoverIndependentInput(id)
        let restored = store.state.jobs[index],recovery = restored.h3InputRecoveries!.last!
        try check("恢复同任务保留全部ID和其他任务",Set(store.state.jobs.map(\.id)) == ids && (try store.state.jobs.filter { $0.id != id }.map { try H3ActionRevisionSelfTests.digest($0) }) == others && restored.h3QueuePlan == plan,"no duplicate tasks, changed frame windows or dependencies")
        let archived = try JSONDecoder().decode(ShotJob.self,from:H3Files.read(URL(fileURLWithPath:recovery.directory + "/previous-job.json")))
        try check("旧阻塞和旧图审完整归档",try H3ActionRevisionSelfTests.digest(archived) == H3ActionRevisionSelfTests.digest(old) && H3Files.read(URL(fileURLWithPath:recovery.directory + "/previous-pixel-review.json")) == oldReview,"immutable prior state and prior QA remain reviewable")
        try check("恢复不沿用旧QA不解除暂停",restored.h3FirstProposal?.pixelReview == nil && !FileManager.default.fileExists(atPath:reviewURL.path) && restored.h3AutomaticWorkflow?.automaticContinuationAuthorized == true && store.state.automaticLaunchesPaused == true && store.state.queuePaused && store.launchCount == 1,"new actual input review is mandatory; no automatic GPU dispatch")
        try check("恢复不改输入和Prompt",restored.h3FirstProposal == old.h3FirstProposal && (try H3Files.read(normalizedURL)) == normalized,"same verified source and descriptor")
        var repeatedRejected = false
        do { try await store.recoverIndependentInput(id) } catch { repeatedRejected = true }
        try check("重复恢复不新增审计或投递",repeatedRejected && store.state.jobs[index].h3InputRecoveries?.count == 1 && store.launchCount == 1,"one recovery activation for one old bug")
        let persisted = try JSONDecoder().decode(WorkspaceState.self,from:H3Files.read(store.root.appendingPathComponent("state.json")))
        try check("恢复审计与新图审门禁持久化",persisted.jobs.first { $0.id == id }?.h3InputRecoveries == restored.h3InputRecoveries && persisted.automaticLaunchesPaused == true,"saved state retains recovery identity and explicit queue pause")
        try H3FirstSelfTests.review(store,id:id,status:"fail");await store.checkFirstPixelReviews()
        try check("恢复后新失败图审进入修订入口",store.state.jobs[index].status == .failed && store.canReviseAction(id) && store.launchCount == 1,"generic independent part can correct a mismatched action without adding a task")
        let request = try H3ActionRevisionSelfTests.makeRequest(store:store,id:id,root:root)
        await store.reviseAction(id,requestURL:request)
        try check("动作修订保留独立恢复审计",store.state.jobs[index].h3FirstProposal?.queueExecution?.actionRevision?.number == 2 && store.state.jobs[index].h3InputRecoveries == restored.h3InputRecoveries && store.state.automaticLaunchesPaused == true && store.launchCount == 1,"same task, revision history and pause; no GPU generation")
        return checks
    }
}
