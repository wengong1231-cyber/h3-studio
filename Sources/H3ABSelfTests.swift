import Foundation
import Darwin
import CoreGraphics

@MainActor enum H3ABSelfTests {
    static func descriptor(work: URL,first: URL,last: URL,scenario: String? = nil) throws -> [String:Any] {
        let helper = work.appendingPathComponent("helper-marker"),library = work.appendingPathComponent("library-marker")
        var value: [String:Any] = ["schema":"jingsheng-App-S41-AB-runtime-contract-v1","ready_for_launch":true,
            "task_descriptor":["shot_number":41,"segment_id":"s41-p01","kind":"native_h3_fl2va_first_and_last","source_configuration_is_per_shot_not_S15_hardcoded":true,"seed_proposal":841041],
            "execution_authority":["App_created_executed_logged_task_required":true,"direct_CLI_launch_allowed":false,"automatic_retry":false,"old92queue_resume":false,"max_generators":1],
            "runtime":["model_ref":"local/MiniMax-H3-FL2VA-8bit","required_partition":"fl2va","lora_ref":"larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema","lora_scale":1,"width":768,"height":448,"native_frames":73,"native_fps":24,"native_duration_seconds":73.0/24,"native_B_anchor_index":72,"native_B_anchor_PTS_seconds":3.0,"video_latent_frames":22,"steps":4,"video_shift":12,"audio_shift":3,"condition_timestep":1,"audio_seconds_setting":0,"memory_cap_mb":12288,"wired_pool_mb":8192,"i8_gemm":false,"unload_when_idle":"always"],
            "conditioning_ports":["first_iport":5,"last_iport":6,"first_stage":"vae-encode-A","last_stage":"vae-encode-B","both_inputs_required":true,"iport7_Ref2VA_reference_rows":false],
            "editorial_target":["frames":72,"fps":24,"duration_seconds":3],
            "duration_adaptation_plan":["keep_native_source0_at_target0":true,"keep_native_source72_at_target71":true,"first72_truncation_allowed":false,"missing_map_blocks_export":true],
            "local_runtime_bindings":["helper_path":helper.path,"helper_sha256":try WorkspaceDigest.sha256(helper),"native_library_path":library.path,"native_library_sha256":try WorkspaceDigest.sha256(library),"registry_working_directory":work.path],
            "inputs":["A":["path":first.path,"sha256":try WorkspaceDigest.sha256(first),"normalized_path":first.path,"normalized_sha256":try WorkspaceDigest.sha256(first),"normalized_visual_review_passed":true],"B":["path":last.path,"sha256":try WorkspaceDigest.sha256(last),"normalized_path":last.path,"normalized_sha256":try WorkspaceDigest.sha256(last),"normalized_visual_review_passed":true]],
            "prompt":["text":"CPU fixture only: two distinct endpoints, actual73 frames.","sha256":H3ABConfigurationReader.digest(Data("CPU fixture only: two distinct endpoints, actual73 frames.".utf8)),"reviewed":true]]
        if let scenario { value["mock_scenario"] = scenario }
        return value
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = [],held: TaskStore?
        func check(_ name: String,_ passed: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail));FileHandle.standardOutput.write(Data("\(passed ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !passed { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        func write(_ path: URL,_ value: [String:Any]) throws { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:path,options:.atomic) }
        func environment(_ name: String,scenario: String? = nil) throws -> (TaskStore,H3Runtime,URL,[String:Any]) {
            let base = root.appendingPathComponent(name),work = base.appendingPathComponent("runtime")
            let runtime = try H3Mock.createRuntime(root:work,executable:executable)
            let inputs = work.appendingPathComponent("proposals/inputs");try FileManager.default.createDirectory(at:inputs,withIntermediateDirectories:true)
            try Data("CPU helper marker; never executable".utf8).write(to:work.appendingPathComponent("helper-marker"))
            try Data("CPU library marker; no model or GPU".utf8).write(to:work.appendingPathComponent("library-marker"))
            let first = inputs.appendingPathComponent("A.png"),last = inputs.appendingPathComponent("B.png")
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:0,width:768,height:448),to:first,width:768,height:448)
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:47,width:768,height:448),to:last,width:768,height:448)
            let value = try descriptor(work:work,first:first,last:last,scenario:scenario),path = work.appendingPathComponent("proposals/S41.json")
            try write(path,value)
            return (try TaskStore(root:base.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime),runtime,path,value)
        }
        do {
            let fm = FileManager.default
            guard !fm.fileExists(atPath:root.path) else { throw StudioError.invalid("S41 CPU 测试必须使用新的隔离目录。") }
            _ = try H3Files.safe(root.path);try fm.createDirectory(at:root,withIntermediateDirectories:true)
            var colors = [UInt8](repeating:0,count:1672*941*4)
            let quadrants: [[UInt8]] = [[240,20,30,255],[30,210,40,255],[20,30,225,255],[215,165,10,255]]
            for y in 0..<941 { for x in 0..<1672 { let color = quadrants[(y<470 ? 0 : 2)+(x<836 ? 0 : 1)],offset = (y*1672+x)*4;colors.replaceSubrange(offset..<offset+4,with:color) } }
            let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!,provider = CGDataProvider(data:Data(colors) as CFData)!
            let source = CGImage(width:1672,height:941,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1672*4,space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let normalized = try H3ABPreprocessor.normalize(source),pixels = normalized.image.dataProvider!.data! as Data
            let positions = [(60,60),(708,60),(60,388),(708,388)]
            let colorPass = positions.enumerated().allSatisfy { index,position in let offset = (position.1*768+position.0)*4;return Array(pixels[offset..<offset+4]) == quadrants[index] }
            try check("CPU 归一色彩与上下方向保持",colorPass && normalized.image.width == 768 && normalized.image.height == 448,"实际RGBA四象限色块通过，不互换红蓝、不倒置，不启动CoreImage或GPU")
            var restartContext: (URL,UUID,H3Runtime,H3Binding,String)?
            do {
            let (store,runtime,path,original) = try environment("normal");held = store
            let id = try await store.importS41Configuration(path),duplicate = try await store.importS41Configuration(path)
            try check("App 独立创建 S41 并去重",id == duplicate && store.state.jobs.count == 1 && store.launchCount == 0 && store.state.queuePaused,"App 保存真实任务与不可变配置，导入不会自动运行")
            let configuration = store.state.jobs[0].h3ABConfiguration!
            try check("原生与成片时长分别保存",configuration.nativeDuration == 73.0/24 && configuration.editorialDuration == 3 && configuration.finalAnchorIndex == 72 && configuration.finalAnchorPTS == 3 && store.state.jobs[0].parameters.frames == 73,"原生73帧，目标72帧；最后锚点raw72，不能沿用124或裁去末帧")
            let snapshot = URL(fileURLWithPath:configuration.snapshotPath!),snapshotHash = try WorkspaceDigest.sha256(snapshot)
            try check("输入配置在执行前持久化",snapshotHash == configuration.sourceSHA256 && store.state.jobs[0].attempts.isEmpty,"配置文件、A/B和提示词指纹先保存，没有占用尝试或启动子进程")
            var changed = original;changed["ready_for_launch"] = false;try write(path,changed)
            _ = try await store.importS41Configuration(path)
            try check("配置更新保留任务与旧快照",store.state.jobs[0].id == id && store.state.jobs[0].h3ABConfiguration?.revision == 2 && !store.canPrepareS41(id) && (try WorkspaceDigest.sha256(snapshot)) == snapshotHash,"显式更新生成新快照；缺项时不能启动")
            try write(path,original);_ = try await store.importS41Configuration(path)
            let binding = try await store.materializeS41(id)
            let native = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(URL(fileURLWithPath:binding.jobPath)))
            let graph = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:native.pipeline_path))) as! [String:Any]
            let stages = graph["stages"] as! [[String:Any]],generate = stages.first { $0["id"] as? String == "generate-video" }!
            let ports = generate["iports"] as! [[String:Any]]
            try check("S41 A/B 与 73 帧管线独立绑定",native.shot_number == 41 && native.profile.frames == 73 && native.seed == 841041 && native.source_image != native.last_source_image && ports[5]["src"] as? String == "vae-encode-A" && ports[6]["src"] as? String == "vae-encode-B" && (generate["config"] as! [String:Any])["frames"] as? Int == 73,"新App UUID身份、独立A/B副本，明确端口5/6与raw72")
            try check("外部导入不能重投 App S41",rejected { _ = try store.importH3Job(URL(fileURLWithPath:binding.jobPath)) },"只能从已有App配置任务进入，不接受外部job伪造新App记录")
            store.startH3(id,approval:.mockForTests(binding.jobSHA256));store.startH3(id,approval:.mockForTests(binding.jobSHA256))
            try check("S41 重复点击仅一个执行",store.launchCount == 1 && store.activeJob?.id == id,"先落盘投递回执，再启动自有监督器；重复点击不建第二个进程")
            try await StudioSelfTests.wait("S41 actual written73 CPU frame progress",timeout:15) { store.activeJob?.progress?.total == 73 }
            try check("S41 进度来自实际文件计数",store.activeJob?.progress?.completed ?? 0 > 0 && store.activeJob?.progress?.total == 73,"每写出一个实际PNG才发计数，非计时百分比")
            try await StudioSelfTests.wait("S41 CPU strict73 completion",timeout:30) { store.activeJob == nil }
            let result = store.state.jobs[0]
            try check("实际73帧与完整AV严格质检",result.status == .completed && result.h3Outcome?.technicalPass == true && result.h3Outcome?.simulated == true && result.h3Outcome?.visualReview == "not_automatically_evaluated" && result.h3Outcome?.selectedForProduction == false,"CPU夹具实际写73张PNG与73帧MP4、静音轨；技术通过不等于真实H3或画面通过。错误：" + (result.error ?? "无"))
            let report = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:result.h3Outcome!.reportPath))) as! [String:Any]
            try check("73帧逐张指纹与锚点回执",(report["lossless_frame_receipts"] as? [[String:Any]])?.count == 73 && report["decoded_video_frames"] as? Int == 73 && report["native73_runtime_observed"] as? Bool == false && report["B_anchor_index"] as? Int == 72 && report["adaptation_executed"] as? Bool == false,"明确CPU模拟、raw0/raw72保留，未执行3秒适配")
            try check("生成与输出检查实际时间分段保存",result.h3GenerationStartedAt != nil && result.h3GenerationEndedAt != nil && result.h3ValidationStartedAt != nil && result.h3ValidationEndedAt != nil,"只有子进程实际启动才登记视频生成；实际检查开始与结束分别保存")
            let videoHash = try WorkspaceDigest.sha256(URL(fileURLWithPath:binding.clipPath))
            store.retry(id);store.startH3(id,approval:.mockForTests(binding.jobSHA256))
            try check("技术完成不自动重投",store.launchCount == 1 && !store.canRunH3(id) && store.state.queuePaused,"下一镜与新尝试始终需要单独任务")
            try await H3ABAcceptanceSelfTests.run(store:store,runtime:runtime,check:check)
            store.shutdown();held = nil
            restartContext = (store.root,id,runtime,binding,videoHash)
            }
            let (normalRoot,id,runtime,binding,videoHash) = restartContext!
            let restored = try TaskStore(root:normalRoot,executable:executable,monitoring:false,h3Runtime:runtime)
            try check("重启恢复完整记录不自动启动",restored.state.jobs[0].id == id && restored.state.jobs[0].status == .completed && restored.state.jobs[0].h3ABConfiguration?.revision == 3 && restored.launchCount == 0 && (try WorkspaceDigest.sha256(URL(fileURLWithPath:binding.clipPath))) == videoHash,"旧候选、配置与用户待审状态恢复，无GPU启动")
            try check("重启保留A/B既有接受及审计",restored.state.jobs[0].h3Outcome?.visualReview == "accepted_existing_user_instruction" && (try H3ABAcceptanceReader.load(job:restored.state.jobs[0],workspace:normalRoot,runtime:runtime)) == restored.state.jobs[0].h3ABAcceptance,"实际落盘再打开，仍绑定同一候选及原用户指令")
            restored.shutdown()
            let (preprocess,preprocessRuntime,preprocessPath,preprocessValue) = try environment("preprocessing");held = preprocess
            var pending = preprocessValue,inputs = pending["inputs"] as! [String:Any]
            for (name,index) in [("A",0),("B",47)] {
                let source = URL(fileURLWithPath:(inputs[name] as! [String:Any])["path"] as! String)
                try fm.removeItem(at:source)
                try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:index,width:1672,height:941),to:source,width:1672,height:941)
                var input = inputs[name] as! [String:Any];input["sha256"] = try WorkspaceDigest.sha256(source);input["normalized_path"] = preprocessRuntime.workDirectory + "/app-inputs/not-generated-" + name + ".png";input["normalized_sha256"] = NSNull();input["normalized_visual_review_passed"] = false;input["source_user_approved"] = true;inputs[name] = input
            }
            pending["schema"] = "jingsheng-App-S41-AB-bound-job-proposal-v2";pending["ready_for_launch"] = false;pending["inputs"] = inputs
            pending["user_authorization"] = ["user_authorized_execution_via_App":true,"direct_CLI_execution_authorized":false]
            var prompt = pending["prompt"] as! [String:Any];prompt.removeValue(forKey:"reviewed");prompt["status"] = "bound_to_confirmed_Av2_and_Brecoveryv3";pending["prompt"] = prompt
            try write(preprocessPath,pending)
            let prepareID = try await preprocess.importS41Configuration(preprocessPath)
            try check("原图获准但归一未齐不能生成",preprocess.canNormalizeS41(prepareID) && !preprocess.canPrepareS41(prepareID) && preprocess.launchCount == 0,"1672×941输入明确登记；用户已授权本次生成，尚无归一预览")
            await preprocess.prepareS41Inputs(prepareID)
            let prepared = preprocess.state.jobs[0].h3ABConfiguration!
            try check("App CPU 归一预处理有真实回执",prepared.preprocessingReceiptPath != nil && prepared.first.normalizedSHA256 != nil && prepared.last.normalizedSHA256 != nil && !prepared.first.visuallyReviewed && prepared.automaticInputsValidated && preprocess.canPrepareS41(prepareID) && preprocess.launchCount == 0,"实际保存768×448 A/B和指纹；不是占位图，不假称人工检查通过。错误：" + (preprocess.state.jobs[0].error ?? "无"))
            let step = preprocess.state.jobs[0].h3InputPreparation!
            try check("图片处理纳入同一App任务生命周期",step.status == "completed" && step.startedAt != nil && step.endedAt != nil && step.images.count == 2 && step.receiptPath == prepared.preprocessingReceiptPath && preprocess.state.jobs[0].h3GenerationStartedAt == nil,"预处理开始前已有任务；原图和实际处理图可预览，真实起止时间与两张完成回执持续保存")
            let preparationReceipt = try JSONSerialization.jsonObject(with:H3Files.read(URL(fileURLWithPath:prepared.preprocessingReceiptPath!))) as! [String:Any]
            let normalizedFrames = preparationReceipt["frames"] as! [[String:Any]],crop = normalizedFrames[0]["source_crop_xyxy"] as! [Double]
            try check("归一图几何与无GPU证据",preparationReceipt["software_renderer"] as? Bool == true && preparationReceipt["gpu_launched"] as? Bool == false && preparationReceipt["native_helper_launched"] as? Bool == false && normalizedFrames.count == 2 && abs(crop[0]-29.42857142857)<0.001 && abs(crop[2]-1642.57142857143)<0.001,"CPU Lanczos中央裁切与已核几何一致；技术检查范围明确，不宣称三头、枪端、双轮或背景语义质量通过")
            try await preprocess.validateS41Inputs(prepareID)
            try check("自动输入检查不伪造人工审核",preprocess.canPrepareS41(prepareID) && preprocess.state.jobs[0].h3ABConfiguration?.first.visuallyReviewed == false && preprocess.state.jobs[0].h3ABConfiguration?.last.visuallyReviewed == false && preprocess.state.jobs[0].h3InputPreparation?.automaticValidationStatus == "completed" && preprocess.launchCount == 0,"完整解码与指纹校验实际通过，保持人工标记为false；生成授权仍受真实配置约束")
            let normSHA = prepared.first.normalizedSHA256
            await preprocess.prepareS41Inputs(prepareID)
            try check("预处理重复点击保持现有素材",preprocess.state.jobs[0].h3ABConfiguration?.first.normalizedSHA256 == normSHA && !preprocess.canNormalizeS41(prepareID) && preprocess.launchCount == 0,"不会覆盖已准备A/B，所有配置版本持续保存")
            let reviewedConfiguration = preprocess.state.jobs[0].h3ABConfiguration!
            let repeatedID = try await preprocess.importS41Configuration(preprocessPath)
            try check("重复导入原提案不会清空归一审核",repeatedID == prepareID && preprocess.state.jobs[0].h3ABConfiguration == reviewedConfiguration && preprocess.canPrepareS41(prepareID),"原提案指纹不变时保留 App 派生配置、输出指纹与审核记录")
            preprocess.shutdown();held = nil
            let (preparationFailure,_,failurePath,failureValue) = try environment("preparation-failure");held = preparationFailure
            var failureDescriptor = failureValue,failureInputs = failureDescriptor["inputs"] as! [String:Any]
            for name in ["A","B"] { var input = failureInputs[name] as! [String:Any];input["normalized_path"] = NSNull();input["normalized_sha256"] = NSNull();input["normalized_visual_review_passed"] = false;failureInputs[name] = input }
            failureDescriptor["inputs"] = failureInputs;try write(failurePath,failureDescriptor)
            let failureID = try await preparationFailure.importS41Configuration(failurePath)
            let changedB = URL(fileURLWithPath:(failureInputs["B"] as! [String:Any])["path"] as! String)
            try Data("CPU test: input changed after registration".utf8).write(to:changedB)
            await preparationFailure.prepareS41Inputs(failureID)
            let failureRecord = preparationFailure.state.jobs[0].h3InputPreparation!
            try check("CPU预处理失败保留已完成图片与错误",failureRecord.status == "failed" && failureRecord.startedAt != nil && failureRecord.endedAt != nil && failureRecord.images.count == 1 && failureRecord.error != nil && preparationFailure.launchCount == 0 && preparationFailure.state.jobs[0].h3GenerationStartedAt == nil && fm.fileExists(atPath:failureRecord.images[0].path),"B指纹在登记后改变，A实际输出保留；App明确失败原因与未进入GPU")
            preparationFailure.shutdown();held = nil
            let (preparationCancel,_,preparationCancelPath,cancelValue) = try environment("preparation-cancel");held = preparationCancel
            var cancelDescriptor = cancelValue,cancelInputs = cancelDescriptor["inputs"] as! [String:Any]
            let cancelSource = URL(fileURLWithPath:(cancelInputs["A"] as! [String:Any])["path"] as! String)
            try fm.removeItem(at:cancelSource)
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:0,width:4096,height:2304),to:cancelSource,width:4096,height:2304)
            for name in ["A","B"] { var input = cancelInputs[name] as! [String:Any];input["normalized_path"] = NSNull();input["normalized_sha256"] = NSNull();input["normalized_visual_review_passed"] = false;cancelInputs[name] = input }
            var cancelA = cancelInputs["A"] as! [String:Any];cancelA["sha256"] = try WorkspaceDigest.sha256(cancelSource);cancelInputs["A"] = cancelA
            cancelDescriptor["inputs"] = cancelInputs;try write(preparationCancelPath,cancelDescriptor)
            let preparationCancelID = try await preparationCancel.importS41Configuration(preparationCancelPath)
            let preparationOperation = Task { await preparationCancel.prepareS41Inputs(preparationCancelID) }
            try await StudioSelfTests.wait("CPU preparation registered before cancelling",timeout:5) { preparationCancel.state.jobs[0].h3InputPreparation?.status == "running" }
            preparationCancel.cancel(preparationCancelID,source:"CPU test during input preparation")
            await preparationOperation.value
            let cancelledPreparation = preparationCancel.state.jobs[0]
            try check("取消图片处理不会误启动视频",cancelledPreparation.status == .cancelled && cancelledPreparation.h3InputPreparation?.status == "cancelled" && cancelledPreparation.h3InputPreparation?.endedAt != nil && cancelledPreparation.h3GenerationStartedAt == nil && preparationCancel.launchCount == 0 && !preparationCancel.canPrepareS41(preparationCancelID),"协作取消检查在解码、转换与逐张写出边界执行；没有GPU尝试或自动恢复")
            preparationCancel.shutdown();held = nil
            let (policy,policyRuntime,policyPath,policyValue) = try environment("policy");held = policy
            func invalid(_ edit: (inout [String:Any]) -> Void) throws -> Bool {
                var value = policyValue;edit(&value);try write(policyPath,value)
                return rejected { _ = try H3ABConfigurationReader.load(policyPath,workDirectory:policyRuntime.workDirectory,mock:true) }
            }
            try check("不能套 S15 或124帧",try invalid { var value = $0["runtime"] as! [String:Any];value["native_frames"] = 124;$0["runtime"] = value },"每镜配置和expected73一致才可登记")
            try check("A/B 端口与并发边界验证",try invalid { var value = $0["conditioning_ports"] as! [String:Any];value["last_iport"] = 5;$0["conditioning_ports"] = value } && (try invalid { var value = $0["execution_authority"] as! [String:Any];value["max_generators"] = 2;$0["execution_authority"] = value }),"末图只能port6，生成器数量只能1")
            try check("不允许两端复制同一张图",try invalid { var value = $0["inputs"] as! [String:Any];value["B"] = value["A"];$0["inputs"] = value },"阻止旧S15同图冒充新A/B收势")
            try check("素材指纹变化即拒绝",try invalid { var value = $0["inputs"] as! [String:Any],a = value["A"] as! [String:Any];a["sha256"] = String(repeating:"0",count:64);value["A"] = a;$0["inputs"] = value },"不信任metadata声称的图片身份")
            try write(policyPath,policyValue)
            let policyID = try await policy.importS41Configuration(policyPath)
            policy.cancel(policyID,source:"CPU test explicit pending cancellation")
            try check("取消来源可追溯且不重排",policy.state.jobs[0].status == .cancelled && policy.state.jobs[0].cancellationSource == "CPU test explicit pending cancellation" && !policy.canPrepareS41(policyID),"记录明确来源，保留快照，H3不自动重试")
            await policy.createS41RetryTask(policyID)
            try check("显式重试创建新记录且不启动",policy.state.jobs.count == 2 && policy.state.jobs[0].id == policyID && policy.state.jobs[0].status == .cancelled && policy.state.jobs[1].id != policyID && policy.state.jobs[1].attempts.isEmpty && policy.launchCount == 0,"旧取消记录不可重投；新UUID任务保留原图身份，一次开始后自动进入各步骤")
            policy.shutdown();held = nil
            let (wrong,_,wrongPath,_) = try environment("wrong-frames",scenario:"wrong_frames");held = wrong
            let wrongID = try await wrong.importS41Configuration(wrongPath);await wrong.startAuthorizedS41(wrongID)
            try await StudioSelfTests.wait("wrong actual72 must fail73 validator",timeout:30) { wrong.activeJob == nil }
            try check("实际72帧不能冒充73帧",wrong.state.jobs[0].status == .failed && wrong.state.jobs[0].h3Outcome == nil && wrong.state.jobs[0].candidate != nil && wrong.launchCount == 1,"native exit0也不足以通过；缺raw72的候选保留且不自动重试")
            wrong.shutdown();held = nil
            let (cancel,_,cancelPath,_) = try environment("cancel",scenario:"cancel_after_output");held = cancel
            let cancelID = try await cancel.importS41Configuration(cancelPath),cancelBinding = try await cancel.materializeS41(cancelID)
            let sentinel = Process();sentinel.executableURL = URL(fileURLWithPath:"/bin/sleep");sentinel.arguments = ["45"];try sentinel.run();defer { if sentinel.isRunning { sentinel.terminate() } }
            cancel.startH3(cancelID,approval:.mockForTests(cancelBinding.jobSHA256))
            try await StudioSelfTests.wait("S41 complete candidate before cancellation",timeout:20) { cancel.state.jobs[0].stage == "CPU 候选已完整写出 · 等待取消测试" && fm.fileExists(atPath:cancelBinding.clipPath) }
            let hash = try WorkspaceDigest.sha256(URL(fileURLWithPath:cancelBinding.clipPath))
            cancel.cancel(cancelID,source:"CPU test after candidate");cancel.cancel(cancelID,source:"CPU test duplicate cancel")
            try await StudioSelfTests.wait("S41 owned cancellation",timeout:10) { cancel.activeJob == nil }
            try check("取消仅停止自有进程并保留候选",cancel.state.jobs[0].status == .cancelled && cancel.state.jobs[0].h3Outcome == nil && sentinel.isRunning && (try WorkspaceDigest.sha256(URL(fileURLWithPath:cancelBinding.clipPath))) == hash && cancel.launchCount == 1,"重复取消幂等；独立sentinel未动，MP4与已写无损帧保留")
            cancel.shutdown();held = nil
            let map = try H3FrameMap73To72(dropping:10);try map.validate()
            try check("3秒适配必须保留两个端点",map.outputToSource.count == 72 && map.outputToSource.first == 0 && map.outputToSource.last == 72 && rejected { _ = try H3FrameMap73To72(dropping:0) } && rejected { _ = try H3FrameMap73To72(dropping:72) },"仅验证显式帧映射；没有导出或裁剪任何用户视频")
            var invalidMap = map;invalidMap.outputToSource = Array(0..<72)
            try check("前72截断与错误映射拒绝",rejected { try invalidMap.validate() },"缺真实海上raw72，不能标成3秒通过")
            let testReport: [String:Any] = ["version":AppIdentity.version,"build":AppIdentity.buildNumber,"nativeGUIStarted":false,"gpuTasksStarted":0,"actualCPUVideoFrames":73,"real73RuntimeValidated":false,"checks":try JSONSerialization.jsonObject(with:JSONEncoder().encode(checks))]
            try JSONSerialization.data(withJSONObject:testReport,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("s41-ab-test-report.json"))
            return 0
        } catch {
            held?.shutdown()
            try? JSONEncoder().encode(checks).write(to:root.appendingPathComponent("s41-ab-failed-checks.json"))
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8));return 1
        }
    }
    static func proposalProfile(report: URL) async -> Int32 {
        do {
            let read = try await Task.detached(priority:.utility) { try H3ABConfigurationReader.load(H3ABConfiguration.knownPath,workDirectory:AppIdentity.modelStatusRoot.path) }.value
            let value = read.configuration
            guard value.launchAuthorized,!value.blockers.isEmpty,value.first.normalizedSHA256 == nil,value.last.normalizedSHA256 == nil,value.proposalID == "app-shot41-AB-recovery-20261006T020242Z" else { throw StudioError.invalid("当前素材提案阶段变化，请重新核对。") }
            let proof: [String:Any] = ["schema":"jingsheng-S41-readonly-proposal-check-v1","version":AppIdentity.version,"build":AppIdentity.buildNumber,"proposalID":value.proposalID!,"proposalSHA256":value.sourceSHA256,"A_originalSHA256":value.first.originalSHA256!,"B_originalSHA256":value.last.originalSHA256!,"promptSHA256":value.promptSHA256!,"inputBytesChecked":true,"sourceAAndBIdentitiesMatchParent":true,"nativeFrames":value.profile.frames,"nativeFPS":value.profile.fps,"editorialFrames":72,"finalAnchorIndex":72,"B_anchorPTS":3,"launchAuthorizedByExistingUserDecision":value.launchAuthorized,"launchBlockedBy":value.blockers,"requiresAppOwnedPreprocessing":true,"appTaskCreated":false,"preprocessingPerformed":false,"nativeGUIStarted":false,"gpuTasksStarted":0,"real73RuntimeValidated":false,"sourceFilesModified":false]
            try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys,.prettyPrinted]).write(to:report,options:.withoutOverwriting)
            FileHandle.standardOutput.write(Data("已核当前 A v2/B 收势 v3 及提示词指纹；未创建任务、归一或启动 GPU。\n".utf8));return 0
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8));return 1 }
    }
}
