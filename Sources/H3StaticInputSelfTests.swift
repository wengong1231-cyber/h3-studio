import Foundation

/// Small CPU protocol tests: no native worker, video encoding, model read,
/// permissions, GUI application, real receipt, or production Workspace writes.
@MainActor enum H3StaticInputSelfTests {
    static func fixtureManifest(_ root: URL) throws -> URL {
        var object = try JSONSerialization.jsonObject(with:H3Files.read(H3QueuePlan.knownPath)) as! [String:Any]
        object["model_workspace_path"] = root.path
        var master = object["effective_current_master"] as! [String:Any]
        master["path"] = root.appendingPathComponent("declared-only-master.mp4").path
        object["effective_current_master"] = master
        let reference = root.appendingPathComponent("identity-protocol-fixture.png")
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:1,width:32,height:24),to:reference,width:32,height:24)
        let referenceHash = try WorkspaceDigest.sha256(reference)
        var rows = object["items"] as! [[String:Any]]
        for i in rows.indices {
            var identity = rows[i]["original_reference_file"] as! [String:Any]
            identity["local_path"] = reference.path;identity["expected_sha256"] = referenceHash;rows[i]["original_reference_file"] = identity
            var parts = rows[i]["parts"] as! [[String:Any]]
            for j in parts.indices {
                let old = URL(fileURLWithPath:parts[j]["prompt_path"] as! String),path = root.appendingPathComponent("proposals/" + old.lastPathComponent)
                if !FileManager.default.fileExists(atPath:path.path) { try H3Files.read(old).write(to:path,options:.withoutOverwriting) }
                parts[j]["prompt_path"] = path.path
                var source = parts[j]["first_image"] as! [String:Any]
                if source["source_media_path"] != nil { source["source_media_path"] = master["path"] }
                parts[j]["first_image"] = source;parts[j].removeValue(forKey:"detailed_first_segment_contract")
            }
            rows[i]["parts"] = parts
        }
        object["items"] = rows
        let url = root.appendingPathComponent("proposals/queue.json")
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
        return url
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ pass: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:pass,detail:detail));print("\(pass ? "PASS" : "FAIL") \(name): \(detail)")
            if !pass { throw StudioError.invalid(name) }
        }
        var store: TaskStore?
        do {
            let fm = FileManager.default
            try fm.createDirectory(at:root.appendingPathComponent("proposals"),withIntermediateDirectories:true)
            try Data("CPU protocol helper placeholder".utf8).write(to:root.appendingPathComponent("mock-helper"))
            try Data("CPU protocol library placeholder".utf8).write(to:root.appendingPathComponent("mock-library"))
            let runtime = H3Runtime.mock(root:root,executable:executable)
            let value = try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
            store = value
            _ = try await value.importPlannedQueue(fixtureManifest(root))
            _ = try await value.importStaticCatalog(H3StaticCatalogReader.knownPath)
            try check("完整图库12张实际指纹与解码",value.staticAssets.count == 12,"real assets read only; no motion or semantic approval inferred")
            let again = try await value.importStaticCatalog(H3StaticCatalogReader.knownPath)
            try check("重复导入图库幂等",again == 0 && value.staticAssets.count == 12,"one immutable handoff snapshot, no duplicate source rows")
            let s37 = value.currentPlannedJob("planned-S37-p01-20261006")!,asset = value.staticAssets.first(where:{ $0.shot == 37 })!
            let binding = try await value.bindStaticInput(s37.id,primary:asset,prompt:asset.motionConstraints,sourceReference:"CPU protocol fixture: known complete static material",prepare:false)
            await value.startPlannedJob(s37.id)
            let job = value.state.jobs.first(where:{ $0.id == s37.id })!,proposal = job.h3FirstProposal!
            try check("S37 静态类型不假冒原片5640帧",proposal.isStaticInput && proposal.sourceFrameIndex == -1 && proposal.sourceFPS == 0 && proposal.sourceMediaFrames == 0,"destination window stays in the frozen plan; no source PTS or film frame claimed")
            let input = proposal.input!
            try check("原图字节与CPU完整归一化",input.originalSHA256 == asset.sha256 && input.originalWidth == 1672 && input.originalHeight == 941 && input.padding.allSatisfy({ $0 >= 0 }),"original source copied unchanged; opaque 768x448 contain preview")
            try check("助手QA前零原生尝试",value.launchCount == 0 && job.attempts.isEmpty && job.h3Binding == nil && job.h3AutomaticWorkflow?.phase == "pixel_qa","no helper process or native claim created")
            var reviewed = proposal
            reviewed.pixelReview = .init(schema:"jingsheng-App-static-input-review-v1",appJobID:s37.id,proposalSHA256:proposal.sourceSHA256,
                sourceMediaSHA256:asset.sha256,sourceFrameIndex:-1,originalSHA256:input.originalSHA256,normalizedSHA256:input.normalizedSHA256,
                promptSHA256:proposal.promptSHA256,status:"pass",reviewerKind:"assistant",observation:"CPU protocol metadata fixture only; this test does not assess scene semantics or submit a real QA receipt.",
                originalPixelsInspected:true,normalizedPixelsInspected:true,promptComparedToActualImage:true,inspectedAt:Date(),
                sourceKind:"complete_static_image",staticBindingSHA256:binding.recordSHA256,motionReferenceSHA256:[],motionReferencePixelsInspected:false)
            try check("静态QA完整指纹绑定",reviewed.reviewReady,"in-memory protocol fixture; never delivered to production or to checkFirstPixelReviews")
            var stale = reviewed;stale.pixelReview!.schema = "jingsheng-App-first-frame-review-v1"
            try check("旧母片QA不能放行静态图",!stale.reviewReady,"source type as well as proposal and image hashes is required")
            stale = reviewed;stale.pixelReview!.staticBindingSHA256 = String(repeating:"0",count:64)
            try check("错误静态绑定QA拒绝",!stale.reviewReady,"matching pixels alone do not establish current input identity")
            try H3FirstTaskBinding.validateProposal(reviewed,descriptorData:H3Files.read(H3Files.safe(proposal.snapshotPath!)),runtime:runtime,jobID:s37.id)
            try check("受支持静态回执通过协议核验",true,"no NativeApp or model launch; complete original and normalized SHA checked")
            let oldHash = proposal.sourceSHA256,oldBytes = try H3Files.read(H3Files.safe(proposal.snapshotPath!))
            _ = try await value.bindStaticInput(s37.id,primary:asset,prompt:asset.motionConstraints + "\nCPU protocol second input revision.",sourceReference:"CPU protocol fixture: explicit second static revision",prepare:false)
            await value.startPlannedJob(s37.id)
            let revised = value.state.jobs.first(where:{ $0.id == s37.id })!.h3FirstProposal!
            let preservedBytes = try H3Files.read(H3Files.safe(proposal.snapshotPath!))
            try check("同UUID静态修订保留旧提案",revised.sourceSHA256 != oldHash && preservedBytes == oldBytes && revised.pixelReview == nil,"new immutable input directory and review path; no old QA reuse")
            let s05 = value.state.jobs.filter { $0.h3QueuePlan?.shot == 5 }.sorted { $0.h3QueuePlan!.part < $1.h3QueuePlan!.part }
            let stageAssets = ["river-valley","closed-eyes","open-eyes-original-reference"].map { stage in value.staticAssets.first(where:{ $0.shot == 5 && $0.stage == stage })! }
            let valid = H3StaticStageAllocation(sourceReference:"CPU fixture allocation only; not a production editorial decision",assignments:s05.enumerated().map { i,j in .init(plan:j.h3QueuePlan!,asset:stageAssets[min(i,2)]) })
            try valid.validate()
            var reversed = valid;reversed.assignments[0].asset = stageAssets[2]
            var rejected = false;do { try reversed.validate() } catch { rejected = true }
            try check("S05阶段倒序拒绝",rejected,"river -> closed -> open must cover the existing 276-frame window; test allocation is never imported")
            let s10Path = H3StaticCatalogReader.knownPath.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("S10-identity-action-repair-20261007-95_4sg3c/S10-Appdev-static-reference-HANDOFF.local.json")
            _ = try await value.importStaticCatalog(s10Path)
            try check("S10三张参考指纹与限制保留",value.staticAssets.filter({ $0.shot == 10 }).count == 3 && value.staticAssets.filter({ $0.shot == 10 }).allSatisfy({ $0.motionConstraints.contains("not certified continuous") }),"reference candidates, no user face/video acceptance or interpolation endpoint certification")
            let s10 = value.state.jobs.filter { $0.h3QueuePlan?.shot == 10 }.sorted { $0.h3QueuePlan!.part < $1.h3QueuePlan!.part }
            for row in s10 {
                let i = value.state.jobs.firstIndex(where:{ $0.id == row.id })!
                value.state.jobs[i].status = .completed
                value.state.jobs[i].attempts = [.init(number:1,startedAt:Date(),endedAt:Date(),status:.completed,directory:root.path + "/old-output-fixture")]
            }
            let ids = try value.redoEntireShot(s10[0].id,reason:"CPU fixture rejection: both prior segments must be retained but invalidated",sourceReference:"CPU protocol fixture explicit redo")
            try check("两段已执行仍可整镜重做",ids.count == 2 && ids.allSatisfy({ id in value.state.jobs.first(where:{ $0.id == id })!.attempts.isEmpty }),"new App identities for both parts, original attempted records preserved")
            try check("整镜重做不沿用旧输入或旧接受",ids.allSatisfy({ id in let j = value.state.jobs.first(where:{ $0.id == id })!;return j.h3Binding == nil && j.h3FirstProposal == nil && j.h3VideoReview == nil }) && !value.canPreparePlannedJob(ids[0]),"new first part explicitly requires static input binding")
            try check("整镜重做重复入口不叠任务",!value.canRedoEntireShot(ids[0]),"fresh empty redo chain is not duplicated")
            let references = value.staticAssets.filter { $0.shot == 10 }
            let ready = references.first(where:{ $0.stage == "ready" })!
            let motion = references.filter { $0.id != ready.id }
            let s10Binding = try await value.bindStaticInput(ids[0],primary:ready,references:motion,prompt:ready.motionConstraints,sourceReference:"CPU protocol fixture: S10 references are not certified endpoints",prepare:false)
            await value.startPlannedJob(ids[0])
            let s10Proposal = value.state.jobs.first(where:{ $0.id == ids[0] })!.h3FirstProposal!
            var s10Reviewed = s10Proposal
            s10Reviewed.pixelReview = .init(schema:"jingsheng-App-static-input-review-v1",appJobID:ids[0],proposalSHA256:s10Proposal.sourceSHA256,
                sourceMediaSHA256:ready.sha256,sourceFrameIndex:-1,originalSHA256:s10Proposal.input!.originalSHA256,normalizedSHA256:s10Proposal.input!.normalizedSHA256,
                promptSHA256:s10Proposal.promptSHA256,status:"pass",reviewerKind:"assistant",observation:"CPU protocol fixture only; no scene assessment or real pixel approval is delivered.",
                originalPixelsInspected:true,normalizedPixelsInspected:true,promptComparedToActualImage:true,inspectedAt:Date(),sourceKind:"complete_static_image",
                staticBindingSHA256:s10Binding.recordSHA256,motionReferenceSHA256:motion.map(\.sha256),motionReferencePixelsInspected:false)
            try check("S10动作参考未检查不能放行",!s10Reviewed.reviewReady,"matching reference hashes require an explicit reference-pixel review flag")
            s10Reviewed.pixelReview!.motionReferencePixelsInspected = true
            try H3FirstTaskBinding.validateProposal(s10Reviewed,descriptorData:H3Files.read(H3Files.safe(s10Proposal.snapshotPath!)),runtime:runtime,jobID:ids[0])
            try check("S10参考复制与QA协议通过",s10Reviewed.reviewReady,"references preserve original bytes and remain identity/action context; no endpoint certification")
            let pipelineData = try H3FirstTaskBinding.pipeline(template:H3ABTaskBinding.template(executable),id:"CPU-static-input-protocol",proposal:s10Reviewed,first:s10Proposal.input!.normalizedPath,directory:root.appendingPathComponent("declared-only-output").path)
            let pipeline = try JSONSerialization.jsonObject(with:pipelineData) as! [String:Any],stages = pipeline["stages"] as! [[String:Any]]
            let generator = stages.first(where:{ $0["id"] as? String == "generate-video" })!,ports = generator["iports"] as! [[String:Any]]
            try check("S10参考没有接入连续末帧port6",ports[6]["src"] as? String == "" && !stages.contains(where:{ $0["id"] as? String == "load-B" }),"pipeline serialization only; no graph or native process executed")
            let nativeBinding = try H3FirstTaskBinding.materialize(jobID:ids[0],workspace:value.root,proposal:s10Reviewed,executable:executable,runtime:runtime)
            let (_,nativeJob) = try H3FirstTaskBinding.load(H3Files.safe(nativeBinding.jobPath),runtime:runtime,requireFresh:true)
            try check("静态候选冻结契约可重新读取",nativeJob.frozen.count <= 32 && nativeJob.last_source_image == nil && value.launchCount == 0,"isolated CPU protocol candidate only; no native helper, model or GPU worker started")
            let sentinel = String(repeating:"a",count:64)
            var review = H3QueueEndpointReview(appJobID:UUID(),requestID:"CPU-provenance",nativeJobSHA256:sentinel,clipSHA256:sentinel,
                reportSHA256:sentinel,selectedRawHalfOpen:[0,68],endpointRawIndex:67,endpointSHA256:sentinel,status:"pass",reviewerKind:"user",
                userEvidenceID:"AppUI_legacy-unattributed",selectedWindowViewed:true,endpointPixelsViewed:true,observation:"CPU-only receipt provenance boundary fixture; no actual user acceptance.",reviewedAt:Date(),acceptanceSource:"app_explicit_accept")
            try check("旧AppUI硬填user不能认证",try !H3AcceptanceAuthority.valid(review,workspace:root,runtime:.real),"legacy claims do not prove actor or authorize continuation")
            review.provenance = .unidentifiedUI
            try check("UI来源actor未知不能认证",try !H3AcceptanceAuthority.valid(review,workspace:root,runtime:.real),"no human attribution inferred from input route")
            let instruction = H3UserVideoAcceptanceInstruction(appJobID:review.appJobID,requestID:review.requestID,nativeJobSHA256:sentinel,
                clipSHA256:sentinel,reportSHA256:sentinel,selectedRawHalfOpen:[0,68],endpointRawIndex:67,endpointSHA256:sentinel,
                sourceReference:"thread:CPU-fixture/message:explicit-source-not-real-user",actorKind:"user",explicitUserAcceptance:true,
                selectedWindowViewed:true,endpointPixelsViewed:true,observation:review.observation,knownVisualRisks:[],instructedAt:Date(),authorizeContinuation:false)
            let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;let instructionBytes = try encoder.encode(instruction),hash = H3ABConfigurationReader.digest(instructionBytes)
            let instructionPath = root.appendingPathComponent("h3-queue-reviews/" + review.appJobID.uuidString + "/acceptance-instructions/" + hash + "/source.json")
            try fm.createDirectory(at:instructionPath.deletingLastPathComponent(),withIntermediateDirectories:true);try instructionBytes.write(to:instructionPath)
            review.acceptanceSource = "external_user_instruction";review.provenance = .init(origin:"external_user_instruction",actorKind:"user",
                sourceReference:instruction.sourceReference,instructionPath:instructionPath.path,instructionSHA256:hash,continuationAuthorized:false)
            try check("明确来源指令须匹配当前指纹",try H3AcceptanceAuthority.valid(review,workspace:root,runtime:.real),"isolated CPU protocol attestation, no actual video or user assertion")
            try check("接受本段不隐含续段授权",try !H3AcceptanceAuthority.valid(review,workspace:root,runtime:.real,requireContinuation:true),"explicit continuation flag required")
            review.clipSHA256 = String(repeating:"b",count:64)
            var mismatch = false;do { _ = try H3AcceptanceAuthority.valid(review,workspace:root,runtime:.real) } catch { mismatch = true }
            try check("外部指令错视频被拒",mismatch,"valid source reference cannot authorize a different clip")
            try check("所有小测试没有原生投递",value.launchCount == 0,"no model downloads, native VPIPE, GPU worker, App restart or installed-bundle mutation")
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        store?.shutdown()
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        if let data = try? encoder.encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
