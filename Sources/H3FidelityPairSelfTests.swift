import Foundation

@MainActor enum H3FidelityPairSelfTests {
    static func run(root: URL,proposal: H3FirstProposal,executable: URL,check: (String,Bool,String) throws -> Void) throws {
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let a = root.appendingPathComponent("fixture-A.png"),b = root.appendingPathComponent("fixture-B.png")
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:0,width:768,height:448),to:a,width:768,height:448)
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:20,width:768,height:448),to:b,width:768,height:448)
        let aHash = try WorkspaceDigest.sha256(a),bHash = try WorkspaceDigest.sha256(b)
        let input = H3FirstInput(originalPath:a.path,originalSHA256:aHash,normalizedPath:a.path,normalizedSHA256:aHash,extractionReceiptPath:root.path + "/fixture-receipt.json",extractionReceiptSHA256:ExecutionFocusSelfTests.hashA,exactFrameIndex:0,actualPTSValue:0,actualPTSTimescale:24,originalWidth:768,originalHeight:448,scale:1,translation:[0,0],padding:[0,0,0,0])
        var p = proposal;p.input = input;p.queueExecution = nil
        var job = ShotJob.fixture(shot:26,title:"isolated A/B input fixture")
        p.pixelReview = .init(schema:"jingsheng-App-first-frame-review-v1",appJobID:job.id,proposalSHA256:p.sourceSHA256,sourceMediaSHA256:p.sourceMediaSHA256,sourceFrameIndex:p.sourceFrameIndex,originalSHA256:aHash,normalizedSHA256:aHash,promptSHA256:p.promptSHA256,status:"pass",reviewerKind:"assistant",observation:"fixture-only check; not production review",originalPixelsInspected:true,normalizedPixelsInspected:true,promptComparedToActualImage:true,inspectedAt:Date())
        let binding = H3Binding(runtime:.real,jobPath:root.path + "/fixture-job.json",jobSHA256:ExecutionFocusSelfTests.hashA,contractSHA256:ExecutionFocusSelfTests.hashA,runnerSHA256:ExecutionFocusSelfTests.hashA,validatorSHA256:ExecutionFocusSelfTests.hashA,nativeJobID:"fixture",outputDirectory:root.path,clipPath:root.path + "/fixture.mp4",profile:p.profile,minimumFreeBytes:0,executionAuthorized:false,appFirstTask:.init(appJobID:job.id,appWorkspace:root.path,proposal:p,configurationPath:root.path + "/fixture-config.json",configurationSHA256:ExecutionFocusSelfTests.hashA,descriptorSnapshotPath:root.path + "/fixture-descriptor.json",pipelineTemplateSHA256:H3ABTaskBinding.templateSHA256))
        job.h3Binding = binding
        let plan = H3FidelityPairPlan(appJobID:job.id,sourceJobSHA256:binding.jobSHA256,firstOriginalSHA256:aHash,lastOriginalPath:b.path,lastOriginalSHA256:bHash,lastWidth:768,lastHeight:448,prompt:"Fixture only: move between two supplied different poses in twenty two frames, locked camera.",purpose:"CPU-only distinct keyframe pipeline test",changedCondition:"Actual different final pose plus matching scoped prompt; no production generation.")
        try plan.validate(jobID:job.id,binding:binding)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let originalJob = try encoder.encode(job),planBytes = try encoder.encode(plan)
        var pair = try H3FidelityPair.freeze(planBytes:planBytes,plan:plan,job:job,input:input,workspace:root.path)
        try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:false)
        try check("不同A/B由App完整归一且分别留档",pair.receipt.firstNormalized.sha256 != pair.receipt.lastNormalized.sha256 && pair.receipt.images.allSatisfy { $0.path.hasPrefix(pair.directory + "/") },"four real fixture images, no gallery-only reference")
        try check("准备A/B不改原任务",try encoder.encode(job) == originalJob && !pair.receipt.generationStarted && !pair.receipt.videoAccepted,"no queue row, acceptance or GPU launch")
        try check("仅准备图片不能替代助手图审",rejected { try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:true) },"required before dispatch")
        try check("不同姿态管线不能缺图审",rejected { _ = try H3Fidelity.pipeline(kind:.motionPairedKeyframes,proposal:p,directory:root.path,pairedInput:pair) },"not enabled by a path alone")
        for field in 0..<5 {
            var bad = plan
            switch field {
            case 0: bad.appJobID = UUID()
            case 1: bad.firstOriginalSHA256 = bHash
            case 2: bad.lastOriginalSHA256 = aHash
            case 3: bad.sourceJobSHA256 = bHash
            default: bad.changedCondition = ""
            }
            try check("A/B拒绝错误绑定\(field)",rejected { try bad.validate(jobID:job.id,binding:binding) },"parent, source, distinct endpoint and concrete change checked")
        }
        let checks = H3FidelityPairReview.requiredChecks.sorted().map { H3FidelityPairReview.Check(id:$0,status:"pass",observation:"Synthetic isolated input fixture inspected by test; never a production QA claim.") }
        let review = H3FidelityPairReview(appJobID:job.id,preparationID:pair.id,preparationSHA256:pair.receiptSHA256,promptSHA256:plan.promptSHA256,status:"pass",observedImages:pair.receipt.images,checks:checks)
        try review.validate(pair:pair)
        for field in 0..<8 {
            var bad = review
            switch field {
            case 0: bad.preparationSHA256 = aHash
            case 1: bad.promptSHA256 = bHash
            case 2: bad.observedImages.removeLast()
            case 3: bad.checks.removeLast()
            case 4: bad.checks[0].status = "fail"
            case 5: bad.videoAccepted = true
            case 6: bad.actor = "user"
            default: bad.appJobID = UUID()
            }
            try check("A/B图审拒绝身份或检查不完整\(field)",rejected { try bad.validate(pair:pair) },"exact four pixels, prompt, actor, checks and input-only scope")
        }
        let reviewRoot = URL(fileURLWithPath:pair.directory + "/reviews")
        try FileManager.default.createDirectory(at:reviewRoot,withIntermediateDirectories:true)
        let reviewURL = reviewRoot.appendingPathComponent("fixture.json"),reviewData = try encoder.encode(review)
        try reviewData.write(to:reviewURL)
        pair.reviews = [.init(path:reviewURL.path,sha256:H3ABConfigurationReader.digest(reviewData),status:"pass",importedAt:Date())]
        try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:true)
        let bytes = try H3Fidelity.pipeline(kind:.motionPairedKeyframes,proposal:p,directory:root.path,pairedInput:pair)
        let graph = try JSONSerialization.jsonObject(with:bytes) as! [String:Any],stages = graph["stages"] as! [[String:Any]]
        let ids = Set(stages.map { $0["id"] as! String }),ports = stages.first { $0["id"] as? String == "generate-video" }!["iports"] as! [[String:Any]]
        try check("两张图实际接入不同首尾端口",ports[5]["src"] as? String == "vae-encode-A" && ports[6]["src"] as? String == "vae-encode-B" && ports[7]["src"] as? String == "" && ports[8]["src"] as? String == "","no reference-encoder substitution")
        try check("A/B管线端口完整且没有隐式裁剪",stages.flatMap { $0["iports"] as! [[String:Any]] }.allSatisfy { let s = $0["src"] as! String;return s.isEmpty || ids.contains(s) } && !ids.contains("normalize-A") && !ids.contains("normalize-B"),"reviewed full-contain inputs used directly")
        let bLoad = stages.first { $0["id"] as? String == "load-B" }!["config"] as! [String:Any]
        try check("B加载遵循已核图像列表协议",bLoad["url"] as? [String] == [root.path + "/input-B.png"],"matches actual S41 loader schema")
        let motion = stages.first { $0["id"] as? String == "generate-video" }!["config"] as! [String:Any]
        let model = stages.first { $0["id"] as? String == "minimax-h3-model-config" }!["config"] as! [String:Any]
        try check("不同姿态仍为22帧8步同种子",motion["frames"] as? Int == 22 && motion["steps"] as? Int == 8 && motion["seed"] as? Int == p.seed && model["lora"] == nil,"bounded diagnostic on existing base model")
        try check("实际Prompt采用已图审的A/B动作",(stages.first { $0["id"] as? String == "text-prompt" }!["config"] as! [String:Any])["text"] as? String == plan.prompt && p.prompt == proposal.prompt,"original production prompt unchanged")
        try check("不同首尾方案不绕去新引擎",!H3FidelityKind.motionPairedKeyframes.usesIsolatedEngine && H3FidelityKind.motionPairedKeyframes.comparisonKind == .motionKeyframeDetail,"compare existing same-image keyframe diagnostic")
        try check("旧方案不能偷偷带入新的B",rejected { _ = try H3Fidelity.pipeline(kind:.motionKeyframeDetail,proposal:p,directory:root.path,pairedInput:pair) },"old graph comparison stays exact")
        try check("日志须证明B真的编码",rejected { try H3Fidelity.validatePairedLog("VaeEncodeStage('vae-encode-A') DiffusionConditionerStage('diffusion-conditioner')") },"wiring labels alone are insufficient")
        try H3Fidelity.validatePairedLog("VaeEncodeStage('vae-encode-A') VaeEncodeStage('vae-encode-B') DiffusionConditionerStage('diffusion-conditioner')")
        var attempt = H3FidelityRecord(id:UUID(),kind:.motionPairedKeyframes,directory:root.path,requestSHA256:aHash,originalSHA256:aHash,pairedInput:pair)
        for status in ["running","completed","failed","cancelled"] {
            attempt.status = status;job.h3FidelityChecks = [attempt]
            try check("同A/B方案不能重复投递\(status)",H3FidelityPair.used(pair,in:job),"all attempt history retained without a numeric cap")
        }
        let oldEncoded = try encoder.encode(ShotJob.fixture(shot:1,title:"old schema"))
        try check("旧任务无需输入字段迁移",try JSONDecoder().decode(ShotJob.self,from:oldEncoded).h3FidelityPairs == nil,"optional pair list is backward compatible")
        let normalizedURL = URL(fileURLWithPath:pair.receipt.lastNormalized.path),goodPixels = try Data(contentsOf:normalizedURL)
        try Data(contentsOf:URL(fileURLWithPath:pair.receipt.firstNormalized.path)).write(to:normalizedURL)
        try check("同尺寸替换B不能沿用图审",rejected { try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:true) },"current normalized pixels hashed again at dispatch and completion")
        try goodPixels.write(to:normalizedURL)
        try Data("tampered review".utf8).write(to:reviewURL)
        try check("改写助手图审时拒绝运行",rejected { try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:true) },"frozen review fingerprint remains required")
        try reviewData.write(to:reviewURL)
        try Data("tampered prompt".utf8).write(to:URL(fileURLWithPath:pair.directory + "/motion-prompt.txt"))
        try check("显示与运行Prompt不同会拦截",rejected { try pair.validate(jobID:job.id,binding:binding,workspace:root.path,requireReview:true) },"copyable prompt exactly matches the reviewed plan")
    }
}
