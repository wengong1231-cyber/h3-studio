import Foundation
import ImageIO

@MainActor enum H3FidelitySelfTests {
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        var store: TaskStore?
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let imageURL = root.appendingPathComponent("original.png")
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:5,width:1672,height:941),to:imageURL,width:1672,height:941)
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(imageURL as CFURL,nil)!,0,nil)!
            let baseline = try H3SourceFrames.contain(image),detail = try H3SourceFrames.contain(image,canvasWidth:1536,canvasHeight:896)
            try check("高细节输入从完整原图取样",detail.image.width == 1536 && detail.image.height == 896 && abs(detail.scale - baseline.scale*2) < 0.00001 && detail.padding.allSatisfy({ $0 >= 0 }),"no generated-video upscaling or cropping")
            try check("任意大尺寸不能越过资源档位",rejected { _ = try H3SourceFrames.contain(image,canvasWidth:8192,canvasHeight:8192) },"only two bounded resolutions")
            let proposal = ExecutionFocusSelfTests.revised(ExecutionFocusSelfTests.planned(shot:26,priority:0),number:2,previousHash:ExecutionFocusSelfTests.hashA).h3FirstProposal!
            for kind in H3FidelityKind.allCases {
                let graph = try JSONSerialization.jsonObject(with:H3Fidelity.pipeline(kind:kind,proposal:proposal,directory:root.path)) as! [String:Any]
                let stages = graph["stages"] as! [[String:Any]],ids = Set(stages.compactMap { $0["id"] as? String })
                let allPorts = stages.flatMap { $0["iports"] as! [[String:Any]] }
                try check("\(kind.rawValue)管线无悬空端口",allPorts.allSatisfy { let id = $0["src"] as! String;return id.isEmpty || ids.contains(id) },"every nonempty source belongs to graph")
                try check("\(kind.rawValue)没有二次裁剪",!ids.contains("normalize-A") && !ids.contains("load-B"),"actual prepared image and no failed tail frame")
                if kind != .motionDetail {
                    try check("\(kind.rawValue)只运行静态片编解码",ids == Set(["model-select","load-A","stack-static-clip","vae-encode-A","vae-decode","save-detail-frames"]),"no text, DiT or video save in codec comparison")
                    let urls = (stages.first { $0["id"] as? String == "load-A" }!["config"] as! [String:Any])["url"] as? [String]
                    let stack = stages.first { $0["id"] as? String == "stack-static-clip" }!
                    let stackConfig = stack["config"] as! [String:Any]
                    try check("\(kind.rawValue)满足原生视频编解码块",urls?.count == 34 && Set(urls ?? []) == [root.path + "/input.png"] && stack["type"] as? String == "temporal-stack" && stackConfig["group_size"] as? Int == 34 && stackConfig["max_mb"] as? Int == 192,"34 identical pixel frames encode to 7 latent frames and decode to 22 frames; no single-anchor decode")
                } else {
                    let config = stages.first { $0["id"] as? String == "generate-video" }!["config"] as! [String:Any]
                    try check("短段改变实际原生分辨率",config["width"] as? Int == 1536 && config["height"] as? Int == 896 && config["frames"] as? Int == 22,"native sample at bounded 22 frames")
                    try check("保留种子与步数隔离对照",config["seed"] as? Int == proposal.seed && config["steps"] as? Int == proposal.profile.steps,"no silent prompt/step change")
                }
            }
            let lock = root.appendingPathComponent("single.lock"),bytes = Data("owned fixture lease".utf8)
            try H3Fidelity.claim(lock,data:bytes)
            try check("单GPU锁拒绝第二次领取",rejected { try H3Fidelity.claim(lock,data:Data("second".utf8)) } && (try Data(contentsOf:lock)) == bytes,"O_EXCL preserves pre-existing lease")
            let output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at:output.appendingPathComponent("frames"),withIntermediateDirectories:true)
            try H3SourceFrames.save(baseline.image,to:output.appendingPathComponent("frames/frame-0000.png"))
            try check("单图不能冒充完整静态编解码结果",rejected { _ = try H3Fidelity.outputReceipts(directory:output.path,kind:.codecBaseline) },"missing 21 native frames rejected")
            for index in 1..<22 {
                try FileManager.default.copyItem(at:output.appendingPathComponent("frames/frame-0000.png"),to:output.appendingPathComponent(String(format:"frames/frame-%04d.png",index)))
            }
            let receipts = try H3Fidelity.outputReceipts(directory:output.path,kind:.codecBaseline)
            try check("输出完整解码并绑定SHA",receipts.count == 22 && (receipts[0]["sha256"] as? String)?.count == 64,"all actual PNGs decoded")
            try check("低分辨率不能冒充高细节输出",rejected { _ = try H3Fidelity.outputReceipts(directory:output.path,kind:.codecDetail) },"wrong pixel dimensions rejected")
            try check("静态低分辨率结果不能冒充高细节短段",rejected { _ = try H3Fidelity.outputReceipts(directory:output.path,kind:.motionDetail) },"wrong native dimensions rejected")
            let parentID = UUID()
            var reviewed = H3FidelityRecord(id:UUID(),kind:.codecBaseline,directory:output.path,requestSHA256:ExecutionFocusSelfTests.hashA,originalSHA256:ExecutionFocusSelfTests.hashB)
            let inputPath = output.appendingPathComponent("input.png")
            try FileManager.default.copyItem(at:output.appendingPathComponent("frames/frame-0000.png"),to:inputPath)
            let report: [String:Any] = ["diagnosticID":reviewed.id.uuidString,"appJobID":parentID.uuidString,"kind":reviewed.kind.rawValue,"recipeVersion":reviewed.recipeVersion,"requestSHA256":reviewed.requestSHA256,
                "originalSHA256":reviewed.originalSHA256,"inputSHA256":try WorkspaceDigest.sha256(inputPath),"videoAccepted":false,"continuationAuthorized":false,
                "status":"technical_complete_visual_review_required","frames":receipts]
            let reportBytes = try JSONSerialization.data(withJSONObject:report,options:.sortedKeys)
            try reportBytes.write(to:URL(fileURLWithPath:reviewed.reportPath));reviewed.reportSHA256 = H3ABConfigurationReader.digest(reportBytes)
            try check("实际报告绑定原图与当前输出",try H3Fidelity.validateReport(reviewed,appJobID:parentID) == reportBytes,"report fingerprint plus all current frame hashes")
            try check("他人任务报告不能冒用",rejected { _ = try H3Fidelity.validateReport(reviewed,appJobID:UUID()) },"parent task identity required")
            let replacement = root.appendingPathComponent("other.png")
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:20,width:768,height:448),to:replacement,width:768,height:448)
            try Data(contentsOf:replacement).write(to:output.appendingPathComponent("frames/frame-0000.png"))
            try check("同尺寸替换像素也不能沿用旧结论",rejected { _ = try H3Fidelity.validateReport(reviewed,appJobID:parentID) },"not only decode or dimensions")
            let testStore = try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false)
            store = testStore
            var old = ShotJob.fixture(shot:26,title:"rejected fixture unchanged");old.status = .completed;old.candidate = "/tmp/fixture-original.mp4"
            var record = H3FidelityRecord(id:UUID(),kind:.codecBaseline,directory:output.path,requestSHA256:ExecutionFocusSelfTests.hashA,originalSHA256:ExecutionFocusSelfTests.hashB)
            record.status = "running";old.h3FidelityChecks = [record];testStore.state.jobs = [old]
            testStore.fidelityJobID = old.id
            try check("对照占用同一生成资源",!testStore.singleGeneratorIdle && !testStore.generatorResourcesIdle && testStore.ownedActiveTask?.id == old.id,"S41 and generic launches share barrier")
            let focus = testStore.executionFocus()
            try check("顶部显示真实保真任务",focus.current?.job.id == old.id && focus.current?.activity.shortState == "保真对照","not idle or accepted candidate")
            testStore.cancelFidelity(old.id)
            try check("取消实验保留原候选",testStore.state.jobs[0].status == .completed && testStore.state.jobs[0].candidate == old.candidate && testStore.state.jobs[0].h3FidelityChecks?[0].status == "cancelling","does not cancel or rewrite parent video")
            try check("保真记录不增加视频分段",testStore.state.jobs.count == 1 && testStore.state.jobs[0].attempts.isEmpty,"separate diagnostic history")
            testStore.finishFidelity(id:old.id,recordID:record.id,code:130)
            try check("取消释放App互斥且不放行视频",testStore.fidelityJobID == nil && testStore.state.jobs[0].h3FidelityChecks?[0].status == "cancelled" && testStore.state.jobs[0].h3VideoReview == nil,"no acceptance or continuation invented")
            try check("重复原输入实验不会自动重投",!testStore.canStartFidelity(old.id,kind:.codecBaseline),"terminal history remains")
            try check("没有报告不能保存结论",rejected { try testStore.recordFidelityObservation(old.id,recordID:record.id,text:"fixture observation is not a video acceptance",finding:.needsMoreReview) },"task/report identity required")
            try check("编解码不能声称运动身份已检查",!H3FidelityFinding.choices(for:.codecBaseline).contains(.motionIdentityDrift) && !H3FidelityFinding.choices(for:.motionDetail).contains(.codecDistortion),"classification follows actual experiment")
            let badCodec = H3FidelityGuidance.make(.codecDistortion,shot:26,kind:.codecDetail)
            try check("编码错误不推给用户改提示词",badCodec.blocksQuality && badCodec.prompt == nil && badCodec.requiredInputs.contains("无需补图"),"developer-owned cause and clear next step")
            let drift = H3FidelityGuidance.make(.motionIdentityDrift,shot:26,kind:.motionDetail)
            try check("身份漂移列出具体素材及补图Prompt",drift.blocksQuality && drift.requiredInputs.contains("各张脸") && drift.prompt?.contains("three-headed, six-armed") == true && drift.promptPurpose?.contains("重绘") == true,"reference prompt distinct from motion prompt")
            let action = H3FidelityGuidance.make(.actionMismatch,shot:26,kind:.motionDetail)
            try check("动作修订草稿明确接触与回弹",action.prompt?.contains("one clear, brief contact") == true && action.prompt?.contains("recoils slightly") == true && action.prompt != drift.prompt,"precise S26 action, no acceptance side effect")
            testStore.shutdown();store = nil
        } catch { checks.append(.init(name:"unexpected",passed:false,detail:error.localizedDescription)) }
        store?.shutdown()
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try? encoder.encode(checks).write(to:root.appendingPathComponent("fidelity-self-test-report.json"))
        return checks.allSatisfy(\.passed) ? 0 : 1
    }
}
