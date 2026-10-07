import Foundation

@MainActor enum H3ReceiptRebindSelfTests {
    static func caseCheck(handoff: URL,output: URL) -> Int32 {
        var result: [String:Any] = ["scope":"Read-only current S19 case assessment; no TaskStore, GUI, GPU, native worker or production writes",
            "productionWrites":false,"realH3Started":false,"guiLaunched":false]
        do {
            let info = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(handoff.path))) as! [String:Any]
            let id = UUID(uuidString:(info["p03"] as! [String:Any])["id"] as! String)!
            let workspace = WorkspaceMigrator.defaultSupportRoot.appendingPathComponent("Workspace")
            let stateURL = workspace.appendingPathComponent("state.json"),before = try H3Files.read(stateURL)
            let state = try JSONDecoder().decode(WorkspaceState.self,from:before)
            guard let job = state.jobs.first(where:{ $0.id == id }),let parentID = job.h3FirstProposal?.queueExecution?.endpoint?.appJobID,
                  let parent = state.jobs.first(where:{ $0.id == parentID }) else { throw StudioError.invalid("实际任务或前段关系缺失。") }
            let assessment = try H3ReceiptRebind.assess(job:job,predecessor:parent,workspace:workspace,runtime:.real)
            result["eligible"] = true;result["appJobID"] = id.uuidString;result["parentAppJobID"] = parentID.uuidString
            result["originalAcceptanceSHA256"] = job.h3FirstProposal!.queueExecution!.endpoint!.reviewSHA256
            result["currentAcceptanceSHA256"] = assessment.currentAcceptanceSHA256
            result["unchangedEndpointSHA256"] = assessment.descriptor.source.endpoint!.imageSHA256
            result["unchangedClipSHA256"] = assessment.descriptor.source.endpoint!.clipSHA256
            result["unchangedPromptSHA256"] = job.h3FirstProposal!.promptSHA256
            result["originalInputQAReusedOnlyForSameContent"] = true
            result["productionStateSHA256Before"] = H3ABConfigurationReader.digest(before)
            result["productionStateSHA256After"] = H3ABConfigurationReader.digest(try H3Files.read(stateURL))
        } catch { result["eligible"] = false;result["error"] = error.localizedDescription }
        do { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.withoutOverwriting) }
        catch { print("FAIL writing local read-only assessment: " + error.localizedDescription);return 1 }
        print(String(data:(try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])) ?? Data(),encoding:.utf8) ?? "")
        return result["eligible"] as? Bool == true ? 0 : 1
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        var owned: TaskStore?
        func check(_ name: String,_ ok: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:ok,detail:detail));print("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
            if !ok { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        do {
            let flow = root.appendingPathComponent("flow")
            let env = try await H3FirstSelfTests.environment(root:flow,executable:executable),store = env.store;owned = store
            _ = try await store.importPlannedQueue(H3QueueExecutionSelfTests.fixtureManifest(env,root:flow))
            let parentID = env.id,childID = store.state.jobs.first { $0.h3QueuePlan?.shot == 19 && $0.h3QueuePlan?.part == 2 }!.id
            await store.startAuthorizedFirst(parentID);try H3FirstSelfTests.review(store,id:parentID);await store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("CPU predecessor",timeout:40) { store.activeJob == nil }
            try H3QueueExecutionSelfTests.endpointReview(store:store,id:parentID)
            await store.startPlannedJob(childID);try H3FirstSelfTests.review(store,id:childID)
            let originalProposal = store.state.jobs.first { $0.id == childID }!.h3FirstProposal!
            let originalQA = try H3Files.read(store.firstReviewURL(childID))
            let originalPreparation = try H3Files.read(URL(fileURLWithPath:originalProposal.input!.extractionReceiptPath))
            let originalDescriptor = try H3Files.read(URL(fileURLWithPath:originalProposal.sourcePath))
            let receipt = H3QueueExecution.reviewURL(workspace:store.root,id:parentID),priorBytes = try H3Files.read(receipt)
            let history = receipt.deletingLastPathComponent().appendingPathComponent("receipt-history/" + H3ABConfigurationReader.digest(priorBytes) + ".json")
            try FileManager.default.createDirectory(at:history.deletingLastPathComponent(),withIntermediateDirectories:true)
            try priorBytes.write(to:history,options:.withoutOverwriting)
            let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            var metadata = try decoder.decode(H3QueueEndpointReview.self,from:priorBytes)
            metadata.observation += " Acceptance source was supplemented for the same CPU fixture content."
            metadata.userEvidenceID = "CPU-only-source-supplement";metadata.provenance = .fixture
            let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let supplemented = try encoder.encode(metadata);try supplemented.write(to:receipt,options:.atomic)
            await store.refreshQueueVideoReviews();await store.checkFirstPixelReviews()
            let failed = store.state.jobs.first { $0.id == childID }!,parent = store.state.jobs.first { $0.id == parentID }!
            try check("复现来源补录后冻结失败且未进入原生",failed.status == .failed && failed.h3AutomaticWorkflow?.phase == "input_freeze" && failed.h3Binding == nil && failed.attempts.isEmpty && store.launchCount == 1,"original strict receipt SHA remains effective; no unsafe implicit fallback")
            let assessment = try H3ReceiptRebind.assess(job:failed,predecessor:parent,workspace:store.root,runtime:store.h3Runtime)
            try check("仅metadata变化可安全评估",assessment.currentAcceptanceSHA256 != originalProposal.queueExecution!.endpoint!.reviewSHA256 && store.canRebindAcceptanceSource(childID),"all actual output, raw endpoint, profile, prompt and acceptance authority revalidated")
            for (name,mutate) in [
                ("视频变化拒绝",{ (r: inout H3QueueEndpointReview) in r.clipSHA256 = String(repeating:"f",count:64) }),
                ("端帧变化拒绝",{ (r: inout H3QueueEndpointReview) in r.endpointSHA256 = String(repeating:"f",count:64) }),
                ("原生任务变化拒绝",{ (r: inout H3QueueEndpointReview) in r.nativeJobSHA256 = String(repeating:"f",count:64) }),
                ("技术报告变化拒绝",{ (r: inout H3QueueEndpointReview) in r.reportSHA256 = String(repeating:"f",count:64) }),
                ("选择窗口变化拒绝",{ (r: inout H3QueueEndpointReview) in r.selectedRawHalfOpen = [0,83] }),
                ("动作修订变化拒绝",{ (r: inout H3QueueEndpointReview) in r.actionRevisionNumber = 2 }),
                ("接受撤销拒绝",{ (r: inout H3QueueEndpointReview) in r.status = "recorded" }),
                ("接续授权撤销拒绝",{ (r: inout H3QueueEndpointReview) in r.provenance?.continuationAuthorized = false })
            ] {
                var changed = metadata;mutate(&changed);try encoder.encode(changed).write(to:receipt,options:.atomic)
                let denied = rejected { _ = try H3ReceiptRebind.assess(job:failed,predecessor:parent,workspace:store.root,runtime:store.h3Runtime) }
                try supplemented.write(to:receipt,options:.atomic)
                try check(name,denied && store.launchCount == 1,"fixture-only mutation; no source refresh may authorize different content or revoked intent")
            }
            let revisedParent = ExecutionFocusSelfTests.revised(parent,number:2,previousHash:String(repeating:"a",count:64))
            try check("当前任务修订与原生输出不一致拒绝",rejected { _ = try H3ReceiptRebind.assess(job:failed,predecessor:revisedParent,workspace:store.root,runtime:store.h3Runtime) },"live App revision must agree with native frozen revision")
            try FileManager.default.removeItem(at:history)
            let missingDenied = rejected { _ = try H3ReceiptRebind.assess(job:failed,predecessor:parent,workspace:store.root,runtime:store.h3Runtime) }
            try priorBytes.write(to:history,options:.withoutOverwriting)
            try check("原接受归档缺失拒绝",missingDenied,"no raw SHA exception without preserved old receipt")
            let ledger = store.root.appendingPathComponent("h3-dispatch/" + String(repeating:"f",count:64) + ".json")
            try JSONEncoder().encode(H3DispatchReceipt(jobSHA256:String(repeating:"f",count:64),nativeJobID:"CPU-claim-fixture",appJobID:childID,sessionID:UUID())).write(to:ledger,options:.withoutOverwriting)
            let claimDenied = rejected { _ = try H3ReceiptRebind.assess(job:failed,predecessor:parent,workspace:store.root,runtime:store.h3Runtime) }
            try FileManager.default.removeItem(at:ledger)
            try check("已有持久领取拒绝恢复",claimDenied,"failed state and zero attempts alone cannot bypass a dispatch receipt")
            let endpoint = originalProposal.queueExecution!.endpoint!
            let rejection = H3VideoRejectionRecord(candidate:.init(appJobID:parentID,requestID:endpoint.requestID,nativeJobSHA256:endpoint.jobSHA256,
                clipSHA256:endpoint.clipSHA256,reportSHA256:endpoint.reportSHA256,actionRevision:nil,promptSHA256:parent.h3FirstProposal!.promptSHA256,staticBindingSHA256:nil),
                reason:"CPU fixture current candidate rejection",origin:"app_ui",actorKind:"unknown",sourceReference:"CPU fixture rejection test only",recordedAt:Date())
            let rejectionURL = H3VideoRejectionReader.url(workspace:store.root,id:parentID)
            try encoder.encode(rejection).write(to:rejectionURL,options:.withoutOverwriting)
            let rejectionDenied = rejected { _ = try H3ReceiptRebind.assess(job:failed,predecessor:parent,workspace:store.root,runtime:store.h3Runtime) }
            try FileManager.default.removeItem(at:rejectionURL)
            try check("已有拒绝不能被来源补录越权",rejectionDenied,"even a valid unchanged acceptance cannot override a rejection record")
            let parentClipHash = try WorkspaceDigest.sha256(URL(fileURLWithPath:parent.candidate!))
            // Reproduce the GUI race: an already scheduled background read
            // occupies the idle gate after the audit has been committed.
            let refresh = Task { @MainActor in
                for _ in 0..<1000 {
                    if store.abConfigurationBusy { store.historyImportInFlight = true;return }
                    try? await Task.sleep(nanoseconds:1_000_000)
                }
            }
            await store.rebindAcceptanceSource(childID);await refresh.value
            let interrupted = store.state.jobs.first { $0.id == childID }!
            let interruptedBridge = interrupted.h3FirstProposal?.queueExecution?.receiptRebind
            try check("后台刷新中断恢复不误报像素变化",interrupted.status.isPending && interrupted.h3FirstProposal?.input == nil && interruptedBridge != nil && interrupted.attempts.isEmpty && store.launchCount == 1 && store.hasAcceptanceRecoveryAction(interrupted),"same persisted audit remains resumable before preparation; no GPU dispatch")
            store.historyImportInFlight = false;store.pauseQueue()
            await store.checkFirstPixelReviews()
            try check("暂停后的恢复不被轮询启动",store.launchCount == 1 && store.state.automaticLaunchesPaused == true,"only an explicit resume releases the interrupted workflow")
            await store.rebindAcceptanceSource(childID);await store.rebindAcceptanceSource(childID)
            guard let running = store.state.jobs.first(where:{ $0.id == childID }),let rebound = running.h3FirstProposal,
                  let bridge = rebound.queueExecution?.receiptRebind else { throw StudioError.invalid(store.notice ?? "rebind not created") }
            try check("App同段恢复并只领取一次",store.activeJob?.id == childID && store.launchCount == 2 && store.state.jobs.count == 33 && running.actionRevisionNumber == failed.actionRevisionNumber,"same App UUID/request/revision; no new acceptance question or duplicate generation")
            try check("中断后沿用同一恢复审计",bridge.id == interruptedBridge?.id,"resuming cannot create another rebind or overwrite the preserved failure")
            try check("旧新回执与失败审计都保留",try H3Files.read(history) == priorBytes && H3Files.read(URL(fileURLWithPath:bridge.directory + "/previous-job.json")) == assessment.previousJob && bridge.previousAcceptanceSHA256 == H3ABConfigurationReader.digest(priorBytes) && bridge.currentAcceptanceSHA256 == H3ABConfigurationReader.digest(supplemented),"old failed state and acceptance bytes preserved; new hash explicitly bound")
            try check("原提案准备与QA没有覆盖",try H3Files.read(URL(fileURLWithPath:originalProposal.sourcePath)) == originalDescriptor && H3Files.read(URL(fileURLWithPath:originalProposal.input!.extractionReceiptPath)) == originalPreparation && H3Files.read(URL(fileURLWithPath:failed.h3FirstProposal!.queueExecution!.appWorkspace + "/h3-config/" + childID.uuidString + "/pixel-review.json")) == originalQA,"fresh nested input directory, immutable new descriptor and QA bridge")
            let previousQA = try decoder.decode(H3FirstPixelReview.self,from:originalQA)
            try check("沿用QA不伪造新检查时间",rebound.pixelReview?.inspectedAt == previousQA.inspectedAt && rebound.pixelReview?.proposalSHA256 != previousQA.proposalSHA256 && rebound.input?.originalSHA256 == originalProposal.input?.originalSHA256 && rebound.input?.normalizedSHA256 == originalProposal.input?.normalizedSHA256,"only audited proposal metadata changed; actual image and prompt evidence are identical")
            var forbidden = rebound.queueExecution!;forbidden.plan.seed += 1
            try check("重绑定证明不允许参数漂移",rejected { try bridge.validate(source:forbidden,runtime:store.h3Runtime) },"source comparison permits only the explicitly recorded acceptance SHA")
            try await StudioSelfTests.wait("rebound CPU continuation",timeout:40) { store.activeJob == nil }
            await store.checkFirstPixelReviews();await store.rebindAcceptanceSource(childID)
            try check("恢复后严格通过且完成不重投",store.state.jobs.first { $0.id == childID }!.h3Outcome?.technicalPass == true && store.launchCount == 2,"real CPU MP4/PNG decoding under the original native segment contract")
            try check("前段视频与端帧不被恢复改写",try WorkspaceDigest.sha256(URL(fileURLWithPath:parent.candidate!)) == parentClipHash && WorkspaceDigest.sha256(URL(fileURLWithPath:endpoint.imagePath)) == endpoint.imageSHA256,"all writes remained in synthetic audit/new-input directories")
            store.shutdown();owned = nil
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription);owned?.shutdown() }
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try? JSONEncoder().encode(checks).write(to:root.appendingPathComponent("test-report.json"),options:.atomic)
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
