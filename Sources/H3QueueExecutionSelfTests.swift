import Foundation

@MainActor enum H3QueueExecutionSelfTests {
    static func fixtureManifest(_ environment: H3FirstSelfTests.Environment,root: URL) throws -> URL {
        var object = try JSONSerialization.jsonObject(with:H3Files.read(H3QueuePlan.knownPath)) as! [String:Any]
        let media = root.appendingPathComponent("fixture-master.mp4"),hash = try WorkspaceDigest.sha256(media)
        var master = object["effective_current_master"] as! [String:Any]
        master["path"] = media.path;master["sha256"] = hash;master["video_frames"] = 48
        master["bytes"] = try media.resourceValues(forKeys:[.fileSizeKey]).fileSize!
        object["effective_current_master"] = master;object["model_workspace_path"] = root.path
        let reference = root.appendingPathComponent("identity-fixture.png")
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:24,width:384,height:216),to:reference,width:384,height:216)
        let referenceHash = try WorkspaceDigest.sha256(reference)
        var rows = object["items"] as! [[String:Any]]
        for i in rows.indices {
            var identity = rows[i]["original_reference_file"] as! [String:Any]
            identity["local_path"] = reference.path;identity["expected_sha256"] = referenceHash;rows[i]["original_reference_file"] = identity
            var parts = rows[i]["parts"] as! [[String:Any]]
            for j in parts.indices {
                let promptSource = URL(fileURLWithPath:parts[j]["prompt_path"] as! String)
                let prompt = root.appendingPathComponent("proposals/" + promptSource.lastPathComponent)
                if !FileManager.default.fileExists(atPath:prompt.path) { try H3Files.read(promptSource).write(to:prompt,options:.withoutOverwriting) }
                parts[j]["prompt_path"] = prompt.path;parts[j]["prompt_sha256"] = try WorkspaceDigest.sha256(prompt)
                var first = parts[j]["first_image"] as! [String:Any]
                if first["source_part_request_id"] == nil {
                    first["source_media_path"] = media.path;first["source_media_sha256"] = hash;first["provisional_global_frame_index"] = 24
                }
                parts[j]["first_image"] = first
                if rows[i]["shot"] as? Int == 19,j == 0 { parts[j]["detailed_first_segment_contract"] = environment.proposalURL.path }
            }
            rows[i]["parts"] = parts
        }
        object["items"] = rows
        let url = root.appendingPathComponent("proposals/queue.json")
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.withoutOverwriting)
        return url
    }
    static func endpointReview(store: TaskStore,id: UUID,wrongHash: Bool = false,cacheState: Bool = true) throws {
        let job = store.state.jobs.first(where:{ $0.id == id })!,plan = job.h3QueuePlan!,binding = job.h3Binding!,outcome = job.h3Outcome!
        let report = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(outcome.reportPath))) as! [String:Any]
        let review = H3QueueEndpointReview(appJobID:id,requestID:plan.requestID,nativeJobSHA256:binding.jobSHA256,
            clipSHA256:report["clip_sha256"] as! String,reportSHA256:try WorkspaceDigest.sha256(H3Files.safe(outcome.reportPath)),
            selectedRawHalfOpen:[plan.selectedRawStart,plan.selectedRawEnd],endpointRawIndex:plan.selectedRawEnd-1,
            endpointSHA256:wrongHash ? String(repeating:"0",count:64) : report["continuation_endpoint_sha256"] as! String,
            status:"pass",reviewerKind:"fixture",userEvidenceID:"CPU-protocol-fixture",selectedWindowViewed:true,endpointPixelsViewed:true,
            observation:"CPU synthetic review response fixture; no real user approval or scene assessment is asserted.",reviewedAt:Date())
        let url = H3QueueExecution.reviewURL(workspace:store.root,id:id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(review).write(to:url,options:.atomic)
        if !wrongHash,cacheState,let i = store.state.jobs.firstIndex(where:{ $0.id == id }) {
            store.state.jobs[i].h3VideoReview = try H3VideoReviewReader.load(job:store.state.jobs[i],workspace:store.root,runtime:store.h3Runtime)
            store.persist()
        }
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        let production = WorkspaceMigrator.defaultSupportRoot.appendingPathComponent("Workspace/state.json")
        let productionBefore = try? H3Files.read(production)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            func exerciseFlow() async throws -> (H3Runtime,URL,UUID,URL) {
            let flow = root.appendingPathComponent("flow"),env = try await H3FirstSelfTests.environment(root:flow,executable:executable)
            let store = env.store,manifest = try fixtureManifest(env,root:flow)
            _ = try await store.importPlannedQueue(manifest)
            func id(_ shot: Int,_ part: Int) -> UUID { store.state.jobs.first(where:{ $0.h3QueuePlan?.shot == shot && $0.h3QueuePlan?.part == part })!.id }
            let p1 = id(19,1),p2 = id(19,2),s35 = id(35,1)
            try check("通用清单33段同身份",store.state.jobs.count == 33 && p1 == env.id,"S19 existing task attached, no duplicate row")
            try check("所有原生配置由清单驱动",Set(store.state.jobs.compactMap { $0.h3QueuePlan?.profile.frames }) == Set([73,90,124]),"no shot-specific execution profile")
            var genericFirsts = 0
            for job in store.state.jobs where job.h3QueuePlan?.part == 1 {
                let data = try H3QueueExecution.descriptor(job:job,predecessor:nil,workspace:store.root,runtime:store.h3Runtime)
                let path = store.root.path + "/h3-config/" + job.id.uuidString + "/queue-proposal.json"
                let parsed = try H3QueueExecution.parse(data,sourcePath:path,runtime:store.h3Runtime).proposal
                guard parsed.profile == job.h3QueuePlan!.profile,parsed.shot == job.shot else { throw StudioError.invalid("generic first configuration mismatch") }
                genericFirsts += 1
            }
            try check("17个独立首段共用描述接口",genericFirsts == 17,"all source, seed, native-length and selected-window parameters read from one manifest")
            await store.startPlannedJob(p2)
            try check("缺前段时等待",store.state.jobs.first(where:{ $0.id == p2 })!.status == .blocked && store.launchCount == 0,"no endpoint guessed, no input directory or worker")
            await store.startAuthorizedFirst(p1);try H3FirstSelfTests.review(store,id:p1);await store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("prior CPU native90",timeout:40) { store.activeJob == nil }
            try check("前段90帧技术完成",store.state.jobs.first(where:{ $0.id == p1 })!.h3Outcome?.technicalPass == true,"CPU candidate, scene review still missing")
            await store.startPlannedJob(p2)
            try check("技术通过不能代替图审",store.state.jobs.first(where:{ $0.id == p2 })!.h3FirstProposal == nil && store.launchCount == 1,"native raw83 held until explicit selected-window review")
            try endpointReview(store:store,id:p1,wrongHash:true);await store.startPlannedJob(p2)
            try check("错误端点SHA不绑定",store.state.jobs.first(where:{ $0.id == p2 })!.h3FirstProposal == nil && store.launchCount == 1,"hash-bound predecessor approval rejected")
            await store.prepareNextPlannedJob()
            try check("阻塞续段不挡独立镜头",store.state.jobs.first(where:{ $0.id == s35 })!.h3FirstProposal?.input != nil && store.launchCount == 1,"invalid p02 approval held; same dispatcher prepared ready S35")
            try endpointReview(store:store,id:p1);await store.startPlannedJob(p2,mockScenario:"slow_generation")
            guard let continuation = store.state.jobs.first(where:{ $0.id == p2 })!.h3FirstProposal,
                  let endpoint = continuation.queueExecution?.endpoint,let input = continuation.input else { throw StudioError.invalid(store.state.jobs.first(where:{ $0.id == p2 })!.error ?? "continuation input missing") }
            try check("续段原样绑定raw83",input.originalSHA256 == endpoint.imageSHA256 && input.normalizedSHA256 == endpoint.imageSHA256 && input.exactFrameIndex == 83,"approved native PNG copied byte-for-byte; no lossy MP4 extraction")
            try check("续段配置窗口与原生长度",continuation.part == 2 && continuation.profile.frames == 90 && continuation.selectedRawStart == 1 && continuation.selectedRawEnd == 85,"same generic pipeline, native90 and explicit [1,85)")
            await store.startPlannedJob(p2)
            try check("重复准备不复制或领取",store.launchCount == 1 && store.state.jobs.count == 33,"same App ID and persisted preparation")
            try H3FirstSelfTests.review(store,id:p2);await store.checkFirstPixelReviews()
            try check("图审后自动领取续段一次",store.launchCount == 2 && store.activeJob?.id == p2,"App worker automatically continues after matching input QA")
            await store.startPlannedJob(s35)
            try check("并发准备不抢执行资源",store.state.jobs.first(where:{ $0.id == s35 })!.h3Binding == nil && store.launchCount == 2,"only one owned worker; pending S35 kept without a second launch")
            try await StudioSelfTests.wait("continuation CPU native90",timeout:40) { store.activeJob == nil }
            let finishedP2 = store.state.jobs.first(where:{ $0.id == p2 })!
            try check("续段90帧严格通过",finishedP2.status == .completed && finishedP2.h3Outcome?.technicalPass == true,"actual CPU MP4 and90 PNGs decoded")
            let p2Report = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(finishedP2.h3Outcome!.reportPath))) as! [String:Any]
            try check("下一端点登记raw84",p2Report["continuation_endpoint_raw_index"] as? Int == 84 && p2Report["continuation_launched"] as? Bool == false,"no automatic p03 launch or editorial trimming")
            await store.startPlannedJob(s35)
            guard let independent = store.state.jobs.first(where:{ $0.id == s35 })!.h3FirstProposal else { throw StudioError.invalid("S35 descriptor missing") }
            try check("S35使用同一入口提母片",independent.shot == 35 && independent.part == 1 && independent.profile.frames == 73 && independent.queueExecution?.endpoint == nil && independent.input != nil,"actual fixture frame, no old identity PNG substitution")
            try H3FirstSelfTests.review(store,id:s35);await store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("independent CPU native73",timeout:40) { store.activeJob == nil }
            try check("S35原生73帧严格通过",store.state.jobs.first(where:{ $0.id == s35 })!.h3Outcome?.technicalPass == true && store.launchCount == 3,"same worker and validation, no shot35 special launcher")
            await store.startPlannedJob(s35);await store.checkFirstPixelReviews()
            try check("完成后不可重投",store.launchCount == 3,"durable attempt-once claim retained")
            let wrongID = id(14,1)
            await store.startPlannedJob(wrongID,mockScenario:"wrong_frames")
            try H3FirstSelfTests.review(store,id:wrongID);await store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("generic native-count failure",timeout:40) { store.activeJob == nil }
            let wrong = store.state.jobs.first(where:{ $0.id == wrongID })!
            try check("通用124帧契约拒绝123帧",wrong.status == .failed && wrong.h3Outcome == nil && wrong.candidate != nil && store.launchCount == 4,"failed candidate retained, no auto retry")
            await store.startPlannedJob(wrongID);await store.checkFirstPixelReviews()
            try check("失败任务不自动重投",store.launchCount == 4,"same App attempt remains terminal")
            let cancelID = id(10,1)
            await store.startPlannedJob(cancelID)
            let retained = store.state.jobs.first(where:{ $0.id == cancelID })!.h3FirstProposal!.input!
            store.cancel(cancelID,source:"generic CPU fixture");try H3FirstSelfTests.review(store,id:cancelID);await store.checkFirstPixelReviews()
            try check("取消与迟到检查不启动",store.launchCount == 4 && store.state.jobs.first(where:{ $0.id == cancelID })!.status == .cancelled,"prepared output remains, no late launch")
            try check("取消保留已准备图片",FileManager.default.fileExists(atPath:retained.originalPath) && FileManager.default.fileExists(atPath:retained.normalizedPath),"no file removed")
            let recoveryID = id(9,1)
            await store.startPlannedJob(recoveryID);let runtime = store.h3Runtime,workspace = store.root;store.shutdown()
            return (runtime,workspace,recoveryID,manifest)
            }
            let context = try await exerciseFlow()
            let recovered = try TaskStore(root:context.1,executable:executable,monitoring:false,h3Runtime:context.0)
            try check("通用待图审任务重启恢复",recovered.state.jobs.first(where:{ $0.id == context.2 })!.h3FirstProposal?.queueExecution != nil && recovered.launchCount == 0,"restored pending input, no native replay")
            let count = try await recovered.importPlannedQueue(context.3)
            try check("通用任务清单重导去重",count == 0 && recovered.state.jobs.count == 33,"cancelled, completed and prepared tasks keep their IDs")
            recovered.cancel(context.2,source:"end generic fixture");recovered.shutdown()
            if let productionBefore {
                let decoded = try JSONDecoder().decode(WorkspaceState.self,from:productionBefore)
                try check("旧正式状态可由新模型解码",decoded.jobs.count > 0,"optional queue source metadata preserves existing App records without mutation")
            }
            try check("运行App状态未被测试修改",productionBefore == (try? H3Files.read(production)),"production workspace read only; no real native process or new app bundle")
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
