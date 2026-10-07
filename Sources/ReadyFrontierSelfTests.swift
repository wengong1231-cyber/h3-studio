import Foundation

@MainActor enum ReadyFrontierSelfTests {
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        var ownedStore: TaskStore?
        func check(_ name: String,_ passed: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail))
            print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
            if !passed { throw StudioError.invalid(name) }
        }
        do {
            func exerciseFlow() async throws -> (H3Runtime,URL,UUID,String) {
            let flow = root.appendingPathComponent("flow")
            let environment = try await H3FirstSelfTests.environment(root:flow,executable:executable)
            let store = environment.store;ownedStore = store
            _ = try await store.importPlannedQueue(H3QueueExecutionSelfTests.fixtureManifest(environment,root:flow))
            let a = environment.id
            let b = store.state.jobs.first { $0.h3QueuePlan?.shot == 35 && $0.h3QueuePlan?.part == 1 }!.id
            let c = store.state.jobs.first { $0.h3QueuePlan?.shot == 19 && $0.h3QueuePlan?.part == 2 }!.id
            let unpreparedCancel = store.state.jobs.first { $0.h3QueuePlan?.shot == 14 && $0.h3QueuePlan?.part == 1 }!
            let restartJob = store.state.jobs.first { $0.h3QueuePlan?.shot == 10 && $0.h3QueuePlan?.part == 1 }!
            let restartPending = store.state.jobs.first { $0.h3QueuePlan?.shot == 9 && $0.h3QueuePlan?.part == 1 }!
            await store.startAuthorizedFirst(a)
            try H3FirstSelfTests.review(store,id:a);await store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("A CPU-only candidate",timeout:40) { store.activeJob == nil }
            try check("A待接受且C依赖未就绪",store.state.jobs.first { $0.id == a }!.status == .completed && !store.canPreparePlannedJob(c),"A is an actual CPU protocol candidate; technical pass does not accept its endpoint")
            await store.startPlannedJob(b);try H3FirstSelfTests.review(store,id:b)
            // Reproduce a previously prepared dependent record at the head.
            // This borrowed input is selection-only fixture data. It never
            // enters materialization; C is restored before genuine preparation.
            let priorC = store.state.jobs.first { $0.id == c }!
            var waitingC = priorC
            waitingC.h3FirstProposal = store.state.jobs.first { $0.id == b }!.h3FirstProposal
            waitingC.h3AutomaticWorkflow = .init(status:"waiting",phase:"pixel_qa",startedAt:Date(),automaticContinuationAuthorized:true)
            let actualA = store.state.jobs.first { $0.id == a }!,actualB = store.state.jobs.first { $0.id == b }!
            var missingReviewHead = actualB;missingReviewHead.id = UUID();missingReviewHead.h3QueuePlan?.priority = -1
            missingReviewHead.h3QueuePlan?.requestID = "CPU-selection-only-missing-review"
            store.state.jobs = [waitingC,actualA,missingReviewHead,actualB];store.persist()
            try check("下一项与真实图审就绪选择一致",store.executionFocus().next?.job.id == b && store.pixelReviewCandidates.first?.id == b,"both skip the unaccepted dependency and an independent head with no QA receipt")
            store.pauseQueue();await store.checkFirstPixelReviews()
            try check("全队列暂停仍允许CPU核对而不启动",store.activeJob == nil && store.launchCount == 1 && store.state.jobs.first { $0.id == b }!.h3FirstProposal?.reviewReady == true && store.executionFocus().next?.queuePaused == true,"the pause applies to H3 continuation as well as fixture dispatch")
            let pausedState = try JSONDecoder().decode(WorkspaceState.self,from:Data(contentsOf:store.root.appendingPathComponent("state.json")))
            try check("全队列暂停持久化",pausedState.queuePaused && pausedState.automaticLaunchesPaused == true,"no timer or restart silently resumes a GPU worker")
            await store.resumeAuthorizedFirstQueue()
            try check("待接受依赖队首不阻独立B运行",store.activeJob?.id == b && store.launchCount == 2,"actual scheduler must skip C and dispatch the independent B CPU worker")
            await store.checkFirstPixelReviews();await store.checkFirstPixelReviews()
            try check("独立B重复检查只领取一次",store.launchCount == 2,"one GPU lease policy exercised with CPU workers")
            try await StudioSelfTests.wait("B CPU-only candidate",timeout:40) { store.activeJob == nil }
            await store.checkFirstPixelReviews()
            try check("B完成后C仍等待A接受",store.launchCount == 2 && store.state.jobs.first { $0.id == c }!.attempts.isEmpty && store.state.jobs.first { $0.id == c }!.h3Binding == nil,"B completion never supplies A's endpoint approval")
            let completedB = store.state.jobs.first { $0.id == b }!
            store.state.jobs[store.state.jobs.firstIndex { $0.id == c }!] = priorC;store.persist()
            await store.acceptVideoAndContinue(a,continueNext:true)
            try check("A应用接受直接解锁真实C准备",store.state.jobs.first { $0.id == a }!.videoContinuationAuthorized && store.state.jobs.first { $0.id == c }!.h3FirstProposal?.input != nil && store.launchCount == 2,"immutable App acceptance action; no second chat confirmation or unaudited endpoint")
            try H3FirstSelfTests.review(store,id:c);store.pauseQueue();await store.checkFirstPixelReviews()
            try check("A接受不会绕过显式全队列暂停",store.launchCount == 2 && store.activeJob == nil && store.executionFocus().next?.job.id == c && store.executionFocus().next?.queuePaused == true,"C remains ready with a valid acceptance and QA, but has no dispatch ledger")
            await store.resumeAuthorizedFirstQueue();await store.checkFirstPixelReviews()
            try check("接受后C只执行一次",store.launchCount == 3 && store.activeJob?.id == c,"real C descriptor binds A's reviewed raw endpoint; durable dispatch prevents duplicates")
            store.pauseQueue()
            try check("暂停后当前C继续并保留真实当前卡",store.activeJob?.id == c && store.executionFocus().current?.job.id == c,"pause only prevents future starts; it does not cancel an owned worker")
            try await StudioSelfTests.wait("C CPU-only candidate",timeout:40) { store.activeJob == nil }
            await store.checkFirstPixelReviews()
            try check("完成输出与单次投递保留",store.state.jobs.first { $0.id == c }!.h3Outcome?.technicalPass == true && store.launchCount == 3 && store.state.jobs.first { $0.id == b }!.candidate == completedB.candidate,"all generated clips are synthetic CPU fixtures")
            let protectedOutputs = try Dictionary(uniqueKeysWithValues:store.state.jobs.filter { [a,b,c].contains($0.id) }.map { job in
                (job.candidate!,try WorkspaceDigest.sha256(URL(fileURLWithPath:job.candidate!)))
            })
            store.add(unpreparedCancel);await store.startPlannedJob(unpreparedCancel.id)
            let cancelledInput = store.state.jobs.first { $0.id == unpreparedCancel.id }!.h3FirstProposal!.input!
            store.cancel(unpreparedCancel.id,source:"CPU ready-frontier late-QA cancellation")
            try H3FirstSelfTests.review(store,id:unpreparedCancel.id);await store.checkFirstPixelReviews()
            try check("取消任务的迟到QA不能启动",store.launchCount == 3 && store.state.jobs.first { $0.id == unpreparedCancel.id }!.status == .cancelled && store.pixelReviewCandidates.allSatisfy { $0.id != unpreparedCancel.id },"cancellation removes this task from the shared frontier")
            try check("取消保留已准备图片和ABC产物",FileManager.default.fileExists(atPath:cancelledInput.normalizedPath) && (try protectedOutputs.allSatisfy { try WorkspaceDigest.sha256(URL(fileURLWithPath:$0.key)) == $0.value }),"no completed clip is deleted or replaced")
            store.cancel(missingReviewHead.id,source:"finish missing-QA selection fixture")
            store.add(restartJob);await store.startPlannedJob(restartJob.id,mockScenario:"slow_generation")
            try H3FirstSelfTests.review(store,id:restartJob.id);await store.checkFirstPixelReviews()
            try check("实际自有CPU进程仍只有一个",store.launchCount == 4 && store.activeJob?.id == restartJob.id,"no parallel worker exists despite ready queue polling")
            store.cancel(restartJob.id,source:"CPU ready-frontier active cancellation");store.cancel(restartJob.id)
            try await StudioSelfTests.wait("cancel active CPU worker",timeout:12) { store.activeJob == nil }
            await store.checkFirstPixelReviews()
            try check("运行取消与重复取消尊重全队列暂停",store.state.jobs.first { $0.id == restartJob.id }!.status == .cancelled && store.launchCount == 4 && store.state.automaticLaunchesPaused == true,"no automatic retry or late resume")
            // A fresh independent job is prepared but never dispatched, to
            // validate restoration of pending QA rather than replay of a claim.
            let pending = restartPending
            store.add(pending);await store.startPlannedJob(pending.id);try H3FirstSelfTests.review(store,id:pending.id)
            let inputHash = store.state.jobs.first { $0.id == pending.id }!.h3FirstProposal!.input!.normalizedSHA256
            let result = (store.h3Runtime,store.root,pending.id,inputHash)
            store.shutdown();ownedStore = nil;return result
            }
            let context = try await exerciseFlow()
            let recovered = try TaskStore(root:context.1,executable:executable,monitoring:false,h3Runtime:context.0);ownedStore = recovered
            await recovered.checkFirstPixelReviews()
            try check("重启恢复待图审输入且不自动执行",recovered.launchCount == 0 && recovered.activeJob == nil && recovered.state.automaticLaunchesPaused == true && recovered.state.jobs.first { $0.id == context.2 }!.h3FirstProposal?.input?.normalizedSHA256 == context.3,"restored QA is validated without acquiring a GPU claim")
            recovered.cancel(context.2,source:"finish CPU recovery fixture");await recovered.checkFirstPixelReviews()
            try check("重启后取消不丢完成产物",recovered.launchCount == 0 && recovered.state.jobs.filter { $0.status == .completed }.count == 3 && recovered.state.jobs.filter { $0.status == .completed }.allSatisfy { FileManager.default.fileExists(atPath:$0.candidate!) },"all ABC clips remain on disk")
            recovered.shutdown();ownedStore = nil
        } catch {
            checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription)
            ownedStore?.shutdown()
        }
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try? JSONEncoder().encode(checks).write(to:root.appendingPathComponent("test-report.json"),options:.atomic)
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
