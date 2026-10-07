import Foundation

@MainActor enum H3RejectionScopeSelfTests {
    static func run(root: URL,executable: URL) async throws -> [StudioSelfTests.Check] {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ passed: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail))
            print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
            if !passed { throw StudioError.invalid(name) }
        }
        let env = try await H3FirstSelfTests.environment(root:root,executable:executable)
        let store = env.store
        defer { store.shutdown() }
        _ = try await store.importPlannedQueue(H3QueueExecutionSelfTests.fixtureManifest(env,root:root))
        let a = env.id
        let b = store.currentPlannedJob("planned-S35-p01-20261006")!.id
        let child = store.currentPlannedJob("planned-S19-p02-20261006")!.id
        let grandchild = store.currentPlannedJob("planned-S19-p03-20261006")!.id
        await store.startAuthorizedFirst(a)
        try H3FirstSelfTests.review(store,id:a);await store.checkFirstPixelReviews()
        try await StudioSelfTests.wait("review-scope CPU candidate",timeout:40) { store.activeJob == nil }
        let parent = store.state.jobs.first { $0.id == a }!
        let clip = URL(fileURLWithPath:parent.candidate!),clipSHA = try WorkspaceDigest.sha256(clip)
        // Selection-only fixtures model a later independent stage and an
        // explicitly cancelled dependent. Neither is sent to materialization.
        var independent = store.state.jobs.first { $0.id == child }!
        independent.id = UUID();independent.h3QueuePlan?.requestID = "CPU-independent-same-shot-stage"
        independent.h3QueuePlan?.part = 4;independent.h3QueuePlan?.dependencyRequestID = nil
        independent.h3QueuePlan?.dependencyRawIndex = nil;independent.stage = "CPU independent static stage"
        independent.h3AutomaticWorkflow = .init(status:"waiting",phase:"pixel_qa",startedAt:Date(),automaticContinuationAuthorized:true)
        var cancelled = store.state.jobs.first { $0.id == child }!
        cancelled.id = UUID();cancelled.h3QueuePlan?.requestID = "CPU-cancelled-dependent"
        cancelled.status = .cancelled;cancelled.stage = "CPU explicit cancellation"
        store.add(independent);store.add(cancelled)
        let independentDigest = try H3ActionRevisionSelfTests.digest(independent)
        let cancelledDigest = try H3ActionRevisionSelfTests.digest(cancelled)
        let scope = H3VideoRejectionScope.affectedIDs(of:parent,jobs:store.state.jobs)
        try check("拒绝范围包含传递依赖",scope.contains(child) && scope.contains(grandchild),"explicit request links, not shot-number ordering")
        try check("同镜独立静态阶段不在拒绝范围",!scope.contains(independent.id) && !scope.contains(b),"later independent stage and unrelated shot remain independent")
        let childIndex = store.state.jobs.firstIndex { $0.id == child }!
        let savedChild = store.state.jobs[childIndex]
        store.state.jobs[childIndex].status = .running
        let receipt = H3VideoRejectionReader.url(workspace:store.root,id:a)
        var blocked = false
        do { try await store.rejectVideo(a,reason:"CPU must not rewrite an endpoint consumed by an active dependent") } catch { blocked = true }
        try check("运行依赖禁止拒绝且不写回执",blocked && !store.canRejectVideo(a) && !FileManager.default.fileExists(atPath:receipt.path),"selection-only active-dependent fixture; no worker is claimed here")
        store.state.jobs[childIndex] = savedChild
        store.fidelityJobID = a
        try check("本任务保真实验保护候选身份",!store.canRejectVideo(a),"diagnostic worker owner is also protected")
        store.fidelityJobID = nil;store.abPreparationID = grandchild
        try check("传递依赖输入准备保护候选身份",!store.canRejectVideo(a),"do not mutate an endpoint while descendants are preparing")
        store.abPreparationID = nil;store.abConfigurationBusy = true
        try check("拒绝与其他配置写入保持串行",!store.canRejectVideo(a),"GPU concurrency is separated from configuration serialization")
        store.abConfigurationBusy = false;store.recoveredPIDs = [Int32.max]
        try check("不明恢复进程仍阻止审查写入",!store.canRejectVideo(a),"unknown worker ownership remains conservative")
        store.recoveredPIDs = [];store.persist()
        await store.startPlannedJob(b,mockScenario:"slow_generation")
        try H3FirstSelfTests.review(store,id:b);await store.checkFirstPixelReviews()
        let running = store.state.jobs.first { $0.id == b }!
        try check("独立CPU生成时可拒绝已完成候选",store.activeJob?.id == b && store.canRejectVideo(a) && store.launchCount == 2,"one actual synthetic worker; no real H3 model or production data")
        store.pauseQueue()
        let ids = Set(store.state.jobs.map(\.id))
        try await store.rejectVideo(a,reason:"CPU protocol fixture: reject the old candidate while an independent worker remains active.")
        let rejected = store.state.jobs.first { $0.id == a }!.h3VideoRejection!
        let receiptBytes = try H3Files.read(URL(fileURLWithPath:rejected.receiptPath))
        try check("保存拒绝不终止独立生成或重复领取",store.activeJob?.id == b && store.launchCount == 2 && store.state.jobs.first { $0.id == b }!.h3Binding == running.h3Binding,"current worker keeps its frozen input and execution identity")
        try check("拒绝只失效待执行依赖",[child,grandchild].allSatisfy { id in
            store.state.jobs.first { $0.id == id }!.stage == "前段候选已拒绝 · 旧端点与旧QA不能接续"
        },"descendants cannot use the rejected endpoint")
        try check("同镜独立与显式取消记录不变",try H3ActionRevisionSelfTests.digest(store.state.jobs.first { $0.id == independent.id }!) == independentDigest && H3ActionRevisionSelfTests.digest(store.state.jobs.first { $0.id == cancelled.id }!) == cancelledDigest,"no implicit invalidation or revival by later part number")
        try check("审查保留暂停与所有任务ID",store.state.automaticLaunchesPaused == true && store.state.queuePaused && Set(store.state.jobs.map(\.id)) == ids,"recording a decision never resumes the queue or creates redo tasks")
        try await store.rejectVideo(a,reason:"CPU duplicate click must keep the original candidate decision")
        try check("生成中重复拒绝幂等",try H3Files.read(URL(fileURLWithPath:rejected.receiptPath)) == receiptBytes && store.launchCount == 2 && WorkspaceDigest.sha256(clip) == clipSHA,"one receipt, untouched candidate, no extra dispatch")
        try await StudioSelfTests.wait("independent CPU worker after rejection",timeout:40) { store.activeJob == nil }
        try check("独立生成完成且拒绝持久化",store.state.jobs.first { $0.id == b }!.h3Outcome?.technicalPass == true && (try H3VideoRejectionReader.read(workspace:store.root,id:a)) == rejected,"real fixture output completes after review; exact candidate SHA remains bound")
        await store.checkFirstPixelReviews()
        try check("拒绝与全队列暂停不触发续段",store.launchCount == 2 && store.state.jobs.first { $0.id == child }!.attempts.isEmpty && store.state.automaticLaunchesPaused == true,"no automatic endpoint acceptance or replay")
        return checks
    }
}
