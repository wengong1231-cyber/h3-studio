import Foundation

struct H3FirstTaskBinding: Codable, Equatable {
    var appJobID: UUID
    var appWorkspace: String
    var proposal: H3FirstProposal
    var configurationPath: String
    var configurationSHA256: String
    var descriptorSnapshotPath: String
    var pipelineTemplateSHA256: String
    var clipName: String { "\(proposal.shortID)-p\(String(format:"%02d",proposal.part))-native-\(proposal.profile.frames)frames.mp4" }

    static func pipeline(template: Data,id: String,proposal: H3FirstProposal,first: String,directory: String) throws -> Data {
        guard H3ABConfigurationReader.digest(template) == H3ABTaskBinding.templateSHA256,
              let inert = try JSONSerialization.jsonObject(with:template) as? [String:Any],
              var graph = inert["pipeline"] as? [String:Any],let original = graph["stages"] as? [[String:Any]] else {
            throw StudioError.invalid("已核 FL2VA 管线模板无法绑定首帧任务。")
        }
        graph["id"] = id
        let removed = Set(["load-B","normalize-B","vae-encode-B","save-detail-source-B"])
        var stages: [[String:Any]] = []
        for var stage in original {
            guard let name = stage["id"] as? String,var config = stage["config"] as? [String:Any] else { throw StudioError.invalid("首帧管线阶段结构不完整。") }
            if removed.contains(name) { continue }
            switch name {
            case "load-A": config["url"] = [first]
            case "text-prompt": config["text"] = proposal.prompt
            case "generate-video":
                config["seed"] = proposal.seed;config["frames"] = proposal.profile.frames
                config["width"] = proposal.profile.width;config["height"] = proposal.profile.height
                config["fps"] = proposal.profile.fps;config["steps"] = proposal.profile.steps
                guard var ports = stage["iports"] as? [[String:Any]],ports.count == 10,
                      ports[5]["src"] as? String == "vae-encode-A",ports[6]["src"] as? String == "vae-encode-B" else {
                    throw StudioError.invalid("已核首帧 port5 或末帧 port6 模板发生变化。")
                }
                ports[6] = ["src":"","oport":0];stage["iports"] = ports
            case "save-video": config["output_url"] = directory + "/" + "\(proposal.shortID)-p\(String(format:"%02d",proposal.part))-native-\(proposal.profile.frames)frames.mp4"
            case "save-detail-frames": config["path"] = directory + "/record/lossless-frames/frame-%04d.png"
            case "save-detail-source": config["path"] = directory + "/record/source-A-resized.png"
            default: break
            }
            stage["config"] = config;stages.append(stage)
        }
        graph["stages"] = stages
        return try JSONSerialization.data(withJSONObject:graph,options:[.sortedKeys,.prettyPrinted])
    }

    static func validateProposal(_ proposal: H3FirstProposal,descriptorData: Data,runtime: H3Runtime,jobID: UUID,allowHistoricalAcceptance: Bool = false) throws {
        if let queue = proposal.queueExecution {
            guard queue.appJobID == jobID else { throw StudioError.invalid("队列配置属于其他 App 任务。") }
        }
        guard proposal.launchAuthorized,proposal.reviewReady,proposal.pixelReview?.appJobID == jobID,let input = proposal.input,
              H3ABConfigurationReader.digest(descriptorData) == proposal.sourceSHA256 else { throw StudioError.invalid("首帧提案、精确源帧或画面检查尚未冻结。") }
        if let rebind = proposal.queueExecution?.receiptRebind {
            guard try proposal.pixelReview == rebind.bridgedReview(proposal:proposal) else { throw StudioError.invalid("来源补录的图审没有沿用同一像素与提示词的原检查。") }
        }
        var expected = proposal;expected.snapshotPath = nil;expected.input = nil;expected.pixelReview = nil
        let read = try H3FirstProposalReader.parse(descriptorData,sourcePath:proposal.sourcePath,runtime:runtime,requireUserProvenance:!allowHistoricalAcceptance)
        guard read.proposal == expected else { throw StudioError.invalid("首帧提案参数或提示词与保存记录不一致。") }
        for path in [input.originalPath,input.normalizedPath,input.extractionReceiptPath] { _ = try H3Files.inside(path,runtime.workDirectory + "/app-inputs") }
        let typedStatic = proposal.queueExecution?.staticInput
        guard input.originalWidth == proposal.sourceWidth,input.originalHeight == proposal.sourceHeight,
              try WorkspaceDigest.sha256(H3Files.safe(input.extractionReceiptPath)) == input.extractionReceiptSHA256 else { throw StudioError.invalid("App 精确提帧回执发生变化。") }
        try H3SourceFrames.technicalImage(input.originalPath,hash:input.originalSHA256,width:proposal.sourceWidth,height:proposal.sourceHeight)
        try H3SourceFrames.technicalImage(input.normalizedPath,hash:input.normalizedSHA256,width:768,height:448)
        let receipt = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(input.extractionReceiptPath),limit:32768)) as? [String:Any]
        if let staticInput = typedStatic {
            guard staticInput.hasRequiredPhaseAllocation,input.sourceKind == "complete_static_image",input.exactFrameIndex == -1,
                  input.actualPTSValue == 0,input.actualPTSTimescale == 0,proposal.sourceFrameIndex == -1,
                  proposal.sourceMediaFrames == 0,proposal.sourceFPS == 0,
                  receipt?["schema"] as? String == "jingsheng-App-static-image-preparation-v1",
                  receipt?["source_kind"] as? String == "complete_static_image",
                  receipt?["film_frame_identity_claimed"] as? Bool == false,
                  receipt?["app_job_id"] as? String == jobID.uuidString,receipt?["proposal_sha256"] as? String == proposal.sourceSHA256,
                  receipt?["static_binding_sha256"] as? String == staticInput.recordSHA256,
                  receipt?["source_asset_id"] as? String == staticInput.primary.id,
                  receipt?["source_path"] as? String == staticInput.primary.path,
                  receipt?["source_sha256"] as? String == staticInput.primary.sha256,
                  input.originalSHA256 == staticInput.primary.sha256,
                  receipt?["original_sha256"] as? String == input.originalSHA256,
                  receipt?["normalized_sha256"] as? String == input.normalizedSHA256,
                  receipt?["whole_image_preserved"] as? Bool == true,receipt?["crop_executed"] as? Bool == false,
                  receipt?["source_crop_xyxy"] as? [Int] == [0,0,proposal.sourceWidth,proposal.sourceHeight],
                  receipt?["motion_references_are_continuous_endpoints"] as? Bool == false,
                  receipt?["exact_zero_based_index"] == nil,receipt?["actual_pts_timescale"] == nil,
                  let references = receipt?["motion_references"] as? [[String:Any]],references.count == staticInput.motionReferences.count else {
                throw StudioError.invalid("静态图回执不完整，或把静态素材、动作参考伪装成母片帧或连续端点。")
            }
            for (reference,asset) in zip(references,staticInput.motionReferences) {
                guard reference["asset_id"] as? String == asset.id,reference["sha256"] as? String == asset.sha256,
                      reference["purpose"] as? String == "identity_and_motion_reference_only",
                      reference["connected_to_port6"] as? Bool == false,let path = reference["path"] as? String else {
                    throw StudioError.invalid("动作参考没有明确绑定完整图和用途。")
                }
                _ = try H3Files.inside(path,URL(fileURLWithPath:input.originalPath).deletingLastPathComponent().path)
                try H3SourceFrames.technicalImage(path,hash:asset.sha256,width:asset.width,height:asset.height)
            }
        } else {
        guard input.sourceKind != "complete_static_image",input.exactFrameIndex == proposal.sourceFrameIndex,
              input.actualPTSTimescale > 0,
              input.actualPTSValue * Int64(proposal.sourceFPS) == Int64(proposal.sourceFrameIndex) * Int64(input.actualPTSTimescale) else { throw StudioError.invalid("视频来源必须有真实精确帧位与 PTS。") }
        guard receipt?["schema"] as? String == "jingsheng-App-exact-source-frame-v1",
              receipt?["app_job_id"] as? String == jobID.uuidString,
              receipt?["proposal_sha256"] as? String == proposal.sourceSHA256,
              receipt?["source_media_sha256"] as? String == proposal.sourceMediaSHA256,
              receipt?["exact_zero_based_index"] as? Int == proposal.sourceFrameIndex,
              receipt?["compressed_CFR_grid_frames_verified"] as? Int == proposal.sourceMediaFrames,
              receipt?["original_sha256"] as? String == input.originalSHA256,
              receipt?["normalized_sha256"] as? String == input.normalizedSHA256,
              receipt?["validation_only"] as? Bool != true,
              (receipt?["actual_pts_value"] as? NSNumber)?.int64Value == input.actualPTSValue,
              receipt?["actual_pts_timescale"] as? Int32 == input.actualPTSTimescale,
              receipt?["whole_image_preserved"] as? Bool == true,receipt?["crop_executed"] as? Bool == false else {
            throw StudioError.invalid("App 源帧回执与实际任务、指纹或完整画面变换不符。")
        }
        if let endpoint = proposal.queueExecution?.endpoint {
            guard receipt?["source_kind"] as? String == "approved_selected_native_endpoint",
                  receipt?["predecessor_review_sha256"] as? String == endpoint.reviewSHA256,
                  input.originalSHA256 == endpoint.imageSHA256,input.normalizedSHA256 == endpoint.imageSHA256 else {
                throw StudioError.invalid("续段输入不是审核通过的原生端点 PNG。")
            }
        }
        }
        guard try WorkspaceDigest.sha256(H3Files.safe(proposal.sourceMediaPath)) == proposal.sourceMediaSHA256 else {
            throw StudioError.invalid("源视频已变化；候选提案不再可启动。")
        }
    }
    static func materialize(jobID: UUID,workspace: URL,proposal: H3FirstProposal,executable: URL,runtime: H3Runtime) throws -> H3Binding {
        guard let snapshot = proposal.snapshotPath else { throw StudioError.invalid("App 首帧提案快照缺失。") }
        _ = try H3Files.inside(snapshot,workspace.path + "/h3-config")
        let descriptorData = try H3Files.read(H3Files.safe(snapshot),limit:1_048_576)
        try validateProposal(proposal,descriptorData:descriptorData,runtime:runtime,jobID:jobID)
        let identity = "app-" + proposal.segment + "-" + jobID.uuidString.lowercased()
        let directory = try H3Files.inside(runtime.workDirectory + "/candidates/" + identity,runtime.workDirectory + "/candidates")
        let fm = FileManager.default
        guard !fm.fileExists(atPath:directory.path) else { throw StudioError.invalid("此 App 首帧任务已有候选目录，不能覆盖或再次领取。") }
        let record = directory.appendingPathComponent("record"),inputs = record.appendingPathComponent("inputs")
        try fm.createDirectory(at:record.appendingPathComponent("lossless-frames"),withIntermediateDirectories:true)
        try fm.createDirectory(at:inputs,withIntermediateDirectories:true)
        let input = proposal.input!
        var frozen: [String:String] = [proposal.sourceMediaPath:proposal.sourceMediaSHA256,proposal.promptPath:proposal.promptSHA256,
            input.originalPath:input.originalSHA256,input.normalizedPath:input.normalizedSHA256,input.extractionReceiptPath:input.extractionReceiptSHA256]
        for (path,hash) in proposal.queueExecution?.frozenFiles ?? [:] { frozen[path] = hash }
        let originalName = proposal.isStaticInput ? "A-original." + URL(fileURLWithPath:input.originalPath).pathExtension : "A-original.png"
        for (name,path,hash) in [(originalName,input.originalPath,input.originalSHA256),("A-normalized.png",input.normalizedPath,input.normalizedSHA256),
                                  (proposal.isStaticInput ? "static-image-preparation.json" : "exact-frame-preparation.json",input.extractionReceiptPath,input.extractionReceiptSHA256)] {
            let target = inputs.appendingPathComponent(name);try fm.copyItem(at:URL(fileURLWithPath:path),to:target)
            guard try WorkspaceDigest.sha256(target) == hash else { throw StudioError.invalid("首帧输入复制指纹不一致。") }
            frozen[target.path] = hash
        }
        if let staticInput = proposal.queueExecution?.staticInput {
            let receipt = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(input.extractionReceiptPath),limit:32768)) as! [String:Any]
            let references = receipt["motion_references"] as! [[String:Any]]
            for (index,pair) in zip(references,staticInput.motionReferences).enumerated() {
                let source = pair.0["path"] as! String,target = inputs.appendingPathComponent("motion-reference-\(index+1)." + URL(fileURLWithPath:source).pathExtension)
                try fm.copyItem(at:H3Files.safe(source),to:target)
                guard try WorkspaceDigest.sha256(target) == pair.1.sha256 else { throw StudioError.invalid("动作参考保存到候选后指纹不同。") }
                frozen[source] = pair.1.sha256;frozen[target.path] = pair.1.sha256
            }
        }
        let descriptor = record.appendingPathComponent("input-contract.json")
        try descriptorData.write(to:descriptor,options:.withoutOverwriting);frozen[descriptor.path] = proposal.sourceSHA256
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let configURL = record.appendingPathComponent("app-configuration.json"),configData = try encoder.encode(proposal)
        try configData.write(to:configURL,options:.withoutOverwriting)
        let configHash = H3ABConfigurationReader.digest(configData);frozen[configURL.path] = configHash
        let metadata = Self(appJobID:jobID,appWorkspace:workspace.path,proposal:proposal,configurationPath:configURL.path,configurationSHA256:configHash,descriptorSnapshotPath:descriptor.path,pipelineTemplateSHA256:H3ABTaskBinding.templateSHA256)
        let pipelineURL = directory.appendingPathComponent(proposal.segment + ".vpipeline")
        let data = try pipeline(template:H3ABTaskBinding.template(executable),id:identity,proposal:proposal,first:inputs.appendingPathComponent("A-normalized.png").path,directory:directory.path)
        try data.write(to:pipelineURL,options:.withoutOverwriting);frozen[pipelineURL.path] = H3ABConfigurationReader.digest(data)
        let job = H3SingleJob(version:3,job_id:identity,shot_number:proposal.shot,segment_id:proposal.segment,
            authorization:.init(user_authorized:true,max_generators:1,no_automatic_retry:true,no_auto_queue:true),
            work_dir:runtime.workDirectory,output_dir:directory.path,pipeline_path:pipelineURL.path,clip_path:directory.path + "/" + metadata.clipName,
            helper_path:proposal.helperPath,helper_sha256:proposal.helperSHA256,library_path:proposal.libraryPath,library_sha256:proposal.librarySHA256,
            source_image:inputs.appendingPathComponent("A-normalized.png").path,source_image_sha256:input.normalizedSHA256,
            model_ref:"local/MiniMax-H3-FL2VA-8bit",lora_ref:"larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",profile:proposal.profile,seed:proposal.seed,
            prompt_sha256:proposal.promptSHA256,frozen:frozen,minimum_free_bytes:runtime.mode == .mock ? 0 : 20 * 1_073_741_824,
            max_wall_seconds:3600,selected_for_production:false,mock_scenario:runtime.mode == .mock ? (proposal.mockScenario ?? "normal") : nil,app_first_task:metadata)
        let jobURL = directory.appendingPathComponent("job.json");try encoder.encode(job).write(to:jobURL,options:.withoutOverwriting)
        return try load(jobURL,runtime:runtime).0
    }
    static func load(_ url: URL,runtime: H3Runtime,requireFresh: Bool = true,allowHistoricalAcceptance: Bool = false) throws -> (H3Binding,H3SingleJob) {
        let job = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(url))
        guard let metadata = job.app_first_task,job.app_ab_task == nil,job.version == 3,
              job.shot_number == metadata.proposal.shot,job.segment_id == metadata.proposal.segment,
              job.job_id == "app-" + metadata.proposal.segment + "-" + metadata.appJobID.uuidString.lowercased(),
              job.profile == metadata.proposal.profile,
              (metadata.proposal.queueExecution != nil || job.profile == .s19First),job.seed == metadata.proposal.seed,
              job.work_dir == runtime.workDirectory,metadata.proposal.workDirectory == runtime.workDirectory,
              job.authorization.user_authorized,job.authorization.max_generators == 1,job.authorization.no_automatic_retry,job.authorization.no_auto_queue,
              job.last_source_image == nil,job.last_source_image_sha256 == nil,!job.selected_for_production,
              job.model_ref == "local/MiniMax-H3-FL2VA-8bit",job.lora_ref == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",
              job.helper_path == metadata.proposal.helperPath,job.helper_sha256 == metadata.proposal.helperSHA256,
              job.library_path == metadata.proposal.libraryPath,job.library_sha256 == metadata.proposal.librarySHA256,
              job.prompt_sha256 == metadata.proposal.promptSHA256,job.source_image_sha256 == metadata.proposal.input?.normalizedSHA256,
              metadata.pipelineTemplateSHA256 == H3ABTaskBinding.templateSHA256,job.frozen.count <= 32,job.max_wall_seconds == 3600,
              runtime.mode == .mock || (job.mock_scenario == nil && job.minimum_free_bytes >= 20 * 1_073_741_824) else { throw StudioError.invalid("首帧任务的 App 身份、输入或串行参数不匹配。") }
        _ = try H3Files.safe(metadata.appWorkspace);_ = try H3Files.inside(job.output_dir,runtime.workDirectory + "/candidates")
        guard job.output_dir == runtime.workDirectory + "/candidates/" + job.job_id,url.path == job.output_dir + "/job.json",
              job.clip_path == job.output_dir + "/" + metadata.clipName,
              job.source_image == job.output_dir + "/record/inputs/A-normalized.png" else { throw StudioError.invalid("首帧任务没有绑定独立候选目录。") }
        let config = try H3Files.inside(metadata.configurationPath,job.output_dir)
        guard try WorkspaceDigest.sha256(config) == metadata.configurationSHA256,
              try JSONDecoder().decode(H3FirstProposal.self,from:H3Files.read(config)) == metadata.proposal else { throw StudioError.invalid("首帧 App 配置快照已变化。") }
        let descriptor = try H3Files.inside(metadata.descriptorSnapshotPath,job.output_dir)
        guard !requireFresh || !allowHistoricalAcceptance else { throw StudioError.invalid("历史回执兼容检查不能用于原生投递。") }
        try validateProposal(metadata.proposal,descriptorData:H3Files.read(descriptor),runtime:runtime,jobID:metadata.appJobID,allowHistoricalAcceptance:allowHistoricalAcceptance)
        var permittedExternal = [metadata.proposal.sourceMediaPath,metadata.proposal.promptPath,metadata.proposal.input!.originalPath,
            metadata.proposal.input!.normalizedPath,metadata.proposal.input!.extractionReceiptPath] + Array((metadata.proposal.queueExecution?.frozenFiles ?? [:]).keys)
        if metadata.proposal.isStaticInput {
            let receipt = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(metadata.proposal.input!.extractionReceiptPath),limit:32768)) as! [String:Any]
            permittedExternal += (receipt["motion_references"] as? [[String:Any]] ?? []).compactMap { $0["path"] as? String }
        }
        for (path,hash) in job.frozen {
            guard path.hasPrefix(job.output_dir + "/") || permittedExternal.contains(path),
                  ModelStatusReader.isHash(hash,length:64),try WorkspaceDigest.sha256(H3Files.safe(path)) == hash else { throw StudioError.invalid("首帧冻结输入或配置发生变化。") }
        }
        guard job.frozen[config.path] == metadata.configurationSHA256,job.frozen[descriptor.path] == metadata.proposal.sourceSHA256,
              job.frozen[job.source_image] == job.source_image_sha256,job.frozen[job.pipeline_path] != nil,
              try H3Files.read(H3Files.inside(job.pipeline_path,job.output_dir)) == pipeline(template:H3Files.readTemplateFallback(),id:job.job_id,
                proposal:metadata.proposal,first:job.source_image,directory:job.output_dir) else { throw StudioError.invalid("首帧管线与实际输入、提示词或 port5/6 配置不同。") }
        if runtime.mode == .real {
            guard runtime == .real,try WorkspaceDigest.sha256(H3Files.safe(job.helper_path)) == H3ABConfigurationReader.helperSHA256,
                  try WorkspaceDigest.sha256(H3Files.safe(job.library_path)) == H3ABConfigurationReader.librarySHA256 else { throw StudioError.invalid("原生执行文件与已核身份不同。") }
        }
        if requireFresh {
            for path in [job.clip_path,job.output_dir + "/attempt-once.json",job.output_dir + "/status.json",job.output_dir + "/technical-validation.json",job.output_dir + "/record/native-run.log"] {
                guard !FileManager.default.fileExists(atPath:path) else { throw StudioError.invalid("首帧任务已领取或已输出，未重跑。") }
            }
            guard try FileManager.default.contentsOfDirectory(atPath:job.output_dir + "/record/lossless-frames").isEmpty else { throw StudioError.invalid("首帧任务原生帧目录已占用。") }
        }
        return (.init(runtime:runtime,jobPath:url.path,jobSHA256:try WorkspaceDigest.sha256(url),contractSHA256:metadata.configurationSHA256,
            runnerSHA256:job.helper_sha256,validatorSHA256:job.library_sha256,nativeJobID:job.job_id,outputDirectory:job.output_dir,clipPath:job.clip_path,
            profile:job.profile,minimumFreeBytes:job.minimum_free_bytes,executionAuthorized:true,appFirstTask:metadata),job)
    }
}

struct H3FirstLaunchCheck {
    var binding: H3Binding
    var completedAt: Date
}
