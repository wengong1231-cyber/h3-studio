import Foundation
import CoreGraphics
import ImageIO

@MainActor enum H3FirstSelfTests {
    // App validation entry: reads the approved real source, writes only to an
    // isolated validation root, never opens TaskStore or a native H3 worker.
    static func validateRealSource(root: URL) async -> Int32 {
        let id = UUID(),started = Date()
        var record: [String:Any] = ["schema":"jingsheng-App-real-source-validation-v1","app_validation_id":id.uuidString,
            "validation_only":true,"production_input_eligible":false,"H3_launched":false,"semantic_quality_assessed":false,
            "source_frame_index":3248,"started_at":ISO8601DateFormatter().string(from:started),"status":"running"]
        func persist() throws { try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("validation-task.json"),options:.atomic) }
        do {
            guard !FileManager.default.fileExists(atPath:root.path) else { throw StudioError.invalid("验证目录已存在，保留旧证据。") }
            _ = try H3Files.safe(root.path)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let read = try H3FirstProposalReader.load(H3FirstProposal.knownPath,runtime:.real),proposal = read.proposal
            record["source_media_path"] = proposal.sourceMediaPath;record["source_media_sha256"] = proposal.sourceMediaSHA256
            record["proposal_sha256"] = proposal.sourceSHA256
            try read.data.write(to:root.appendingPathComponent("source-proposal.json"),options:.withoutOverwriting);try persist()
            let recorder = try H3SourceValidationRecorder(root:root)
            let input = try await Task.detached(priority:.utility) {
                try probeSource(proposal.sourceMediaPath,root:root)
                return try await H3SourceFrames.prepare(proposal,jobID:id,control:H3PreparationControl(),validationRoot:root.appendingPathComponent("inputs")) { event in await recorder.append(event) }
            }.value
            await recorder.finish()
            record["status"] = "completed";record["passed"] = true
            record["input"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(input))
            record["ended_at"] = ISO8601DateFormatter().string(from:Date());try persist()
            print("PASS real S19 source global3248: " + input.originalPath)
            print("NORMALIZED " + input.normalizedPath)
            return 0
        } catch {
            record["status"] = "failed";record["passed"] = false;record["error"] = error.localizedDescription
            record["ended_at"] = ISO8601DateFormatter().string(from:Date());try? persist()
            print("FAIL real S19 source validation: " + error.localizedDescription);return 1
        }
    }
    nonisolated static func probeSource(_ source: String,root: URL) throws {
        let probe = URL(fileURLWithPath:AppIdentity.ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probeAvailable = FileManager.default.isExecutableFile(atPath:probe.path)
        let executable = probeAvailable ? probe : URL(fileURLWithPath:AppIdentity.ffmpeg)
        // Input metadata only: no output, transcoding, decoder, or new tool.
        let arguments = probeAvailable ? ["-v","error","-select_streams","v:0","-show_entries",
            "stream=index,codec_name,has_b_frames,time_base,start_pts,start_time,avg_frame_rate,r_frame_rate,duration_ts,nb_frames:packet=pts,dts,duration,size,flags","-of","json",source] : ["-hide_banner","-i",source]
        let result = root.appendingPathComponent("container-probe.json"),stderr = root.appendingPathComponent("container-probe.stderr.txt")
        try Data().write(to:result,options:.withoutOverwriting);try Data().write(to:stderr,options:.withoutOverwriting)
        let out = try FileHandle(forWritingTo:result),err = try FileHandle(forWritingTo:stderr)
        defer { try? out.close();try? err.close() }
        let process = Process();process.executableURL = executable;process.arguments = arguments
        process.standardInput = FileHandle.nullDevice;process.standardOutput = out;process.standardError = err
        try process.run();let owner = try OwnedProcessScope(process:process),deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.02) }
        if process.isRunning { owner.root.signal(SIGTERM);throw StudioError.invalid("只读源视频 probe 超时。") }
        process.waitUntilExit()
        guard process.terminationStatus == (probeAvailable ? 0 : 1) else { throw StudioError.invalid("只读源视频 probe 失败。") }
        try JSONSerialization.data(withJSONObject:["schema":"jingsheng-App-read-only-container-probe-v1","executable":executable.path,"arguments":arguments,"exit_code":process.terminationStatus,"ffprobe_available":probeAvailable,"read_only":true,"video_generated":false],options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("container-probe-invocation.json"),options:.withoutOverwriting)
    }
    struct Environment {
        var store: TaskStore
        var proposalURL: URL
        var id: UUID
    }
    static func movie(_ url: URL) async throws {
        let directory = url.deletingLastPathComponent().appendingPathComponent("fixture-source-frames")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for index in 0..<48 {
            let rgb = FixtureWorker.makeFrame(frame:index,width:384,height:216)
            var data = Data("P6\n384 216\n255\n".utf8);data.append(rgb)
            try data.write(to:directory.appendingPathComponent(String(format:"frame-%04d.ppm",index)),options:.withoutOverwriting)
        }
        try await Task.detached(priority:.utility) {
            let process = Process();process.executableURL = URL(fileURLWithPath:AppIdentity.ffmpeg)
            process.arguments = ["-hide_banner","-loglevel","error","-nostdin","-n","-threads","1","-filter_threads","1",
                "-framerate","24","-i",directory.path + "/frame-%04d.ppm","-frames:v","48","-c:v","libx264","-preset","ultrafast","-threads","1","-pix_fmt","yuv420p",url.path]
            process.standardInput = FileHandle.nullDevice;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.standardError
            try process.run();process.waitUntilExit();guard process.terminationStatus == 0 else { throw StudioError.invalid("S19 CPU 源视频夹具封装失败。") }
        }.value
    }
    static func environment(root: URL,executable: URL,scenario: String = "normal") async throws -> Environment {
        let fm = FileManager.default
        try fm.createDirectory(at:root.appendingPathComponent("proposals"),withIntermediateDirectories:true)
        let media = root.appendingPathComponent("fixture-master.mp4")
        try await movie(media)
        let helper = root.appendingPathComponent("mock-helper"),library = root.appendingPathComponent("mock-library")
        try Data("CPU-only mock helper".utf8).write(to:helper);try Data("CPU-only mock library".utf8).write(to:library)
        let prompt = root.appendingPathComponent("proposals/prompt.txt")
        try Data("CPU synthetic source frame; fixture verifies the App task protocol and never generates real H3.".utf8).write(to:prompt)
        // Clone only the supplied contract structure; source materials and all
        // generation paths below are replaced by this isolated CPU fixture.
        var object = try JSONSerialization.jsonObject(with:H3Files.read(H3FirstProposal.knownPath)) as! [String:Any]
        let mediaHash = try WorkspaceDigest.sha256(media)
        var baseline = object["baseline"] as! [String:Any]
        baseline["preferred_master_path"] = media.path;baseline["preferred_master_sha256"] = mediaHash
        baseline["preferred_master_bytes"] = try media.resourceValues(forKeys:[.fileSizeKey]).fileSize!
        baseline["container_metadata_read_only_verified"] = ["video_frames":48,"width":384,"height":216,"fps":24,"video_timescale":12288,"constant_frame_duration_ticks":512]
        object["baseline"] = baseline
        var first = object["first_image"] as! [String:Any]
        first["source_media_path"] = media.path;first["source_media_sha256"] = mediaHash;first["zero_based_global_index"] = 24
        first["S19_local_index"] = 24;object["first_image"] = first
        var destination = object["destination"] as! [String:Any];destination["part1_global_half_open"] = [24,108];object["destination"] = destination
        var native = object["native_generation"] as! [String:Any]
        native["prompt_path"] = prompt.path;native["prompt_sha256"] = try WorkspaceDigest.sha256(prompt)
        native["helper_path"] = helper.path;native["library_path"] = library.path
        native["work_dir"] = root.path;native["model_registry_required_cwd"] = root.path;object["native_generation"] = native
        var evidence = object["native_length_evidence"] as! [String:Any]
        evidence["helper_sha256"] = try WorkspaceDigest.sha256(helper);evidence["library_sha256"] = try WorkspaceDigest.sha256(library);object["native_length_evidence"] = evidence
        object["mock_scenario"] = scenario
        let proposal = root.appendingPathComponent("proposals/S19-first.json")
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:proposal)
        let runtime = H3Runtime.mock(root:root,executable:executable)
        let store = try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
        let id = try await store.importFirstProposal(proposal)
        return .init(store:store,proposalURL:proposal,id:id)
    }
    static func review(_ store: TaskStore,id: UUID,status: String = "pass",wrongHash: Bool = false) throws {
        let p = store.state.jobs.first(where:{ $0.id == id })!.h3FirstProposal!,input = p.input!
        let value = H3FirstPixelReview(schema:"jingsheng-App-first-frame-review-v1",appJobID:id,proposalSHA256:p.sourceSHA256,
            sourceMediaSHA256:p.sourceMediaSHA256,sourceFrameIndex:p.sourceFrameIndex,
            originalSHA256:wrongHash ? String(repeating:"0",count:64) : input.originalSHA256,
            normalizedSHA256:input.normalizedSHA256,promptSHA256:p.promptSHA256,status:status,reviewerKind:"assistant",
            observation:"CPU synthetic QA response fixture; all production scene acceptance remains unassessed.",
            originalPixelsInspected:true,normalizedPixelsInspected:true,promptComparedToActualImage:true,inspectedAt:Date())
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted];encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to:store.firstReviewURL(id),options:.atomic)
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let real = try H3FirstProposalReader.load(H3FirstProposal.knownPath,runtime:.real).proposal
            try check("真实契约只读解析",real.shot == 19 && real.part == 1 && real.sourceFrameIndex == 3248 && real.profile.frames == 90 && real.targetFrames == 84 && real.input == nil && !real.reviewReady,
                "只读 supplied S19 p01；未提取真实母片或启动真实引擎")
            let normal = try await environment(root:root.appendingPathComponent("normal"),executable:executable)
            let store = normal.store,id = normal.id
            try check("提案导入不执行",store.launchCount == 0 && store.canStartFirstWorkflow(id) && store.state.jobs.count == 1,"App 保存唯一身份与不可变提案快照")
            let duplicate = try await store.importFirstProposal(normal.proposalURL)
            try check("导入提案去重",duplicate == id && store.state.jobs.count == 1 && store.launchCount == 0,"相同提案只保留一个 App 任务")
            var heartbeats = 0
            let heartbeat = Timer.scheduledTimer(withTimeInterval:0.01,repeats:true) { _ in Task { @MainActor in heartbeats += 1 } }
            let preparation = Task { await store.startAuthorizedFirst(id) }
            try await StudioSelfTests.wait("S19 preparation ownership") { store.abWorkflowID == id || store.state.jobs[0].h3FirstProposal?.input != nil || store.state.jobs[0].status == .failed }
            await store.startAuthorizedFirst(id);await preparation.value;heartbeat.invalidate()
            let prepared = store.state.jobs[0]
            guard let input = prepared.h3FirstProposal?.input else { throw StudioError.invalid(prepared.error ?? "S19 prepared input missing") }
            try check("一次开始实际提帧与归一",prepared.h3InputPreparation?.status == "completed" && prepared.h3InputPreparation?.images.count == 2 && prepared.h3AutomaticWorkflow?.phase == "pixel_qa" && store.launchCount == 0,
                "CPU actual source frame + normalized PNG written; scene QA not invented")
            try check("精确索引与实际PTS",input.exactFrameIndex == 24 && input.actualPTSValue * 24 == Int64(input.actualPTSTimescale) * 24,"source global24 = PTS1.000s; zero tolerance and complete CFR grid")
            try check("完整缩放补边",abs(input.scale-2) < 0.00001 && input.padding == [0,8,0,8] && input.originalWidth == 384 && input.originalHeight == 216,
                "384×216→768×432 plus8px rows; no source crop")
            let receipt = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:input.extractionReceiptPath))) as! [String:Any]
            try check("提帧真实回执",receipt["compressed_CFR_grid_frames_verified"] as? Int == 48 && receipt["whole_image_preserved"] as? Bool == true && receipt["crop_executed"] as? Bool == false && receipt["semantic_quality_assessed"] as? Bool == false && receipt["H3_launched"] as? Bool == false,"source/PNG hashes, actual PTS, exact transform and actual phase times retained")
            try check("提帧不阻塞界面Actor",heartbeats > 0,"MainActor timer continued while source hashing, sample inspection and image processing ran detached")
            await store.startAuthorizedFirst(id)
            try check("准备期间及准备后重复开始安全",store.launchCount == 0 && store.state.jobs.count == 1 && prepared.id == id,"没有重复图片处理或 GPU 领取")
            try review(store,id:id,wrongHash:true);await store.checkFirstPixelReviews()
            try check("错图检查结果不启动",store.launchCount == 0 && store.state.jobs[0].status.isPending && store.state.jobs[0].h3FirstProposal?.pixelReview == nil,"旧/错 PNG 指纹 cannot release current native task")
            var deniedImport = false
            do { try await store.importInputReview(store.firstReviewURL(id),id:id) } catch { deniedImport = true }
            try check("App图审入口拒绝错图指纹",deniedImport && store.launchCount == 0,"导入动作不能跳过图片和提案身份检查")
            try review(store,id:id);store.pauseQueue()
            try await store.importInputReview(store.firstReviewURL(id),id:id)
            let reviewHistory = store.firstReviewURL(id).deletingLastPathComponent().appendingPathComponent("input-review-history")
            try check("App图审归档且尊重暂停",store.state.jobs[0].h3FirstProposal?.reviewReady == true && store.launchCount == 0 && (try FileManager.default.contentsOfDirectory(atPath:reviewHistory.path)).count == 1 && store.state.jobs[0].logTail.contains { $0.hasPrefix("App 导入输入图审：") },"实际输入已核对，图审来源归档，显式暂停仍有效")
            await store.resumeAuthorizedFirstQueue()
            try check("检查通过自动接续一次",store.launchCount == 1 && store.activeJob?.id == id && store.state.jobs[0].h3Binding?.appFirstTask != nil,"fixture QA response automatically froze input and entered App-owned CPU worker")
            await store.checkFirstPixelReviews();await store.startAuthorizedFirst(id)
            try check("重复检查不重复领取",store.launchCount == 1,"durable App claim and only one worker")
            let binding = store.state.jobs[0].h3Binding!
            let graph = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:binding.appFirstTask!.proposal.snapshotPath!))) as! [String:Any]
            try check("原始提案快照未改写",graph["schema"] as? String == "H3-App-S19-first-segment-preparation-v1","App-generated input data stored separately")
            let jobData = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(URL(fileURLWithPath:binding.jobPath)))
            let pipeline = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:jobData.pipeline_path))) as! [String:Any]
            let stages = pipeline["stages"] as! [[String:Any]],generate = stages.first { $0["id"] as? String == "generate-video" }!
            let ports = generate["iports"] as! [[String:Any]],config = generate["config"] as! [String:Any]
            try check("每镜管线首帧port5末帧断开",ports[5]["src"] as? String == "vae-encode-A" && ports[6]["src"] as? String == "" && !stages.contains { $0["id"] as? String == "load-B" } && config["frames"] as? Int == 90 && config["seed"] as? Int == 841019,
                "S19 independent A-only graph,90f; no S41/S15 identity or copied end anchor")
            try await StudioSelfTests.wait("S19 CPU native candidate",timeout:35) { store.activeJob == nil }
            let result = store.state.jobs[0]
            guard let outcome = result.h3Outcome else { throw StudioError.invalid(result.error ?? "S19 CPU native output not accepted") }
            let output = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:outcome.reportPath))) as! [String:Any]
            try check("90帧完整严格检查",result.status == .completed && outcome.technicalPass && outcome.simulated && output["decoded_video_frames"] as? Int == 90 && output["native_lossless_frames"] as? Int == 90,
                "actual CPU MP490 frames +90 lossless PNGs fully decoded; not real H3")
            try check("选择窗口与端点只登记",output["selected_raw_half_open"] as? [Int] == [0,84] && output["continuation_endpoint_raw_index"] as? Int == 83 && output["adaptation_executed"] as? Bool == false && output["continuation_launched"] as? Bool == false,
                "raw83 hash retained; no CLI trimming, continuation or master replacement")
            try check("候选质量未冒称通过",output["native90_runtime_observed"] as? Bool == false && output["semantic_quality_assessed"] as? Bool == false && outcome.selectedForProduction == false,
                "mock runtime cannot become real90-frame evidence or full-shot acceptance")
            let candidateHash = try WorkspaceDigest.sha256(URL(fileURLWithPath:result.candidate!))
            let importedAgain = try await store.importFirstProposal(normal.proposalURL);await store.startAuthorizedFirst(id)
            try check("完成任务不重投",importedAgain == id && store.launchCount == 1 && candidateHash == (try WorkspaceDigest.sha256(URL(fileURLWithPath:result.candidate!))),"same proposal identity keeps completed native candidate")
            store.shutdown()

            let bad = try await environment(root:root.appendingPathComponent("bad-source"),executable:executable)
            try Data("changed source".utf8).write(to:URL(fileURLWithPath:bad.store.state.jobs[0].h3FirstProposal!.sourceMediaPath))
            await bad.store.startAuthorizedFirst(bad.id)
            try check("坏源视频不进入生成",bad.store.state.jobs[0].status == .failed && bad.store.launchCount == 0 && bad.store.state.jobs[0].h3FirstProposal?.input == nil,"source size/SHA mismatch stops before frame extraction or native claim")
            bad.store.shutdown()

            let cancel = try await environment(root:root.appendingPathComponent("cancel"),executable:executable)
            await cancel.store.startAuthorizedFirst(cancel.id)
            let completedInput = cancel.store.state.jobs[0].h3FirstProposal!.input!
            cancel.store.cancel(cancel.id,source:"CPU test cancel before scene QA")
            try review(cancel.store,id:cancel.id);await cancel.store.checkFirstPixelReviews()
            try check("取消后到达的检查不启动",cancel.store.state.jobs[0].status == .cancelled && cancel.store.launchCount == 0,"late scene QA cannot advance cancelled task")
            try check("取消保留实际预览",FileManager.default.fileExists(atPath:completedInput.originalPath) && FileManager.default.fileExists(atPath:completedInput.normalizedPath),"already prepared source and normalized PNGs remain")
            cancel.store.shutdown()

            let failedQA = try await environment(root:root.appendingPathComponent("failed-QA"),executable:executable)
            await failedQA.store.startAuthorizedFirst(failedQA.id);try review(failedQA.store,id:failedQA.id,status:"fail");await failedQA.store.checkFirstPixelReviews()
            try check("画面失败转材料修复",failedQA.store.state.jobs[0].status == .failed && failedQA.store.launchCount == 0 && failedQA.store.state.jobs[0].h3AutomaticWorkflow?.automaticContinuationAuthorized == false,
                "specific observation retained; no local image substitution or endless rerun")
            failedQA.store.shutdown()

            let wrong = try await environment(root:root.appendingPathComponent("wrong-native-count"),executable:executable,scenario:"wrong_frames")
            await wrong.store.startAuthorizedFirst(wrong.id);try review(wrong.store,id:wrong.id);await wrong.store.checkFirstPixelReviews()
            try await StudioSelfTests.wait("wrong S19 frame count",timeout:35) { wrong.store.activeJob == nil }
            try check("原生89帧不能通过90帧契约",wrong.store.state.jobs[0].status == .failed && wrong.store.state.jobs[0].h3Outcome == nil && wrong.store.launchCount == 1 && wrong.store.state.jobs[0].candidate != nil,
                "failed native output retained; no fake90, auto retry or continuation")
            wrong.store.shutdown()

            let recoveryRoot = root.appendingPathComponent("recovery")
            let (runtime,recoveryID) = try await prepareRecovery(root:recoveryRoot,executable:executable)
            let restored = try TaskStore(root:recoveryRoot.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
            try check("等待检查的重启恢复",restored.state.jobs[0].id == recoveryID && restored.state.jobs[0].h3FirstProposal?.input != nil && restored.state.jobs[0].h3AutomaticWorkflow?.phase == "pixel_qa" && restored.launchCount == 0,
                "persisted extraction and waiting review recovered; no silent native replay")
            restored.cancel(recoveryID,source:"end CPU restart fixture");restored.shutdown()
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
    static func prepareRecovery(root: URL,executable: URL) async throws -> (H3Runtime,UUID) {
        let prepared = try await environment(root:root,executable:executable)
        await prepared.store.startAuthorizedFirst(prepared.id)
        let result = (prepared.store.h3Runtime,prepared.id);prepared.store.shutdown();return result
    }
}

private actor H3SourceValidationRecorder {
    private let handle: FileHandle
    init(root: URL) throws {
        let url = root.appendingPathComponent("validation-events.jsonl")
        try Data().write(to:url,options:.withoutOverwriting);handle = try FileHandle(forWritingTo:url)
    }
    func append(_ event: EngineEvent) {
        if var data = try? JSONEncoder().encode(event) { data.append(10);try? handle.write(contentsOf:data) }
        if event.type == "stage" { print(event.stage ?? "") }
    }
    func finish() { try? handle.close() }
}
