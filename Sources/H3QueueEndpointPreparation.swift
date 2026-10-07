import Foundation

extension H3SourceFrames {
    static func prepareEndpoint(_ proposal: H3FirstProposal,jobID: UUID,runtime: H3Runtime,control: H3PreparationControl,progress: Progress) async throws -> H3FirstInput {
        try control.check()
        guard let source = proposal.queueExecution,source.appJobID == jobID,let endpoint = source.endpoint,
              let snapshot = proposal.snapshotPath else { throw StudioError.invalid("续段缺少队列绑定和已审核端点。") }
        let current = try H3QueueExecution.parse(H3Files.read(H3Files.safe(snapshot)),sourcePath:proposal.sourcePath,runtime:runtime).proposal
        var expected = proposal;expected.snapshotPath = nil;expected.input = nil;expected.pixelReview = nil
        guard current == expected else { throw StudioError.invalid("续段冻结配置与当前审核端点不一致。") }
        let started = Date(),clip = try H3Files.safe(endpoint.clipPath)
        await progress(.init(type:"stage",stage:"核对前段画面审核与精确端点"))
        guard try await sourceHash(clip,expectedBytes:proposal.sourceMediaBytes,control:control,progress:progress) == endpoint.clipSHA256 else {
            throw StudioError.invalid("前段原生视频指纹变化。")
        }
        let bytes = try H3Files.read(H3Files.safe(endpoint.imagePath),limit:50_331_648)
        guard H3ABConfigurationReader.digest(bytes) == endpoint.imageSHA256 else { throw StudioError.invalid("所选原生端点图片已变化。") }
        try technicalImage(endpoint.imagePath,hash:endpoint.imageSHA256,width:proposal.sourceWidth,height:proposal.sourceHeight)
        let suffix = source.receiptRebind.map { "/receipt-rebinds/" + $0.id.uuidString } ?? ""
        let directory = try H3Files.inside(runtime.workDirectory + "/app-inputs/App-source-frames/" + jobID.uuidString + suffix,runtime.workDirectory + "/app-inputs")
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw StudioError.invalid("续段已有输入目录，保留原文件，不重复覆盖。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original = directory.appendingPathComponent("source-frame-\(endpoint.rawIndex).png"),normalized = directory.appendingPathComponent("A-normalized.png")
        try control.check();try bytes.write(to:original,options:.withoutOverwriting)
        await progress(.init(type:"prepared_original",path:original.path,message:endpoint.imageSHA256))
        try control.check()
        await progress(.init(type:"stage",stage:"保存完整已审核端点 · 原样 PNG"))
        try bytes.write(to:normalized,options:.withoutOverwriting)
        await progress(.init(type:"prepared_normalized",path:normalized.path,message:endpoint.imageSHA256))
        try technicalImage(normalized.path,hash:endpoint.imageSHA256,width:proposal.profile.width,height:proposal.profile.height)
        try control.check()
        let receiptURL = directory.appendingPathComponent("exact-frame-preparation.json")
        let receipt: [String:Any] = [
            "schema":"jingsheng-App-exact-source-frame-v1","app_job_id":jobID.uuidString,"proposal_sha256":proposal.sourceSHA256,
            "source_kind":"approved_selected_native_endpoint","source_media_path":endpoint.clipPath,"source_media_sha256":endpoint.clipSHA256,
            "exact_zero_based_index":endpoint.rawIndex,"actual_pts_value":endpoint.rawIndex,"actual_pts_timescale":proposal.sourceFPS,
            "compressed_CFR_grid_frames_verified":proposal.sourceMediaFrames,
            "grid_evidence":"prior App strict full video and lossless-frame technical report; endpoint selected by logical native raw index",
            "predecessor_app_job_id":endpoint.appJobID.uuidString,"predecessor_request_id":endpoint.requestID,
            "predecessor_technical_report_path":endpoint.reportPath,"predecessor_technical_report_sha256":endpoint.reportSHA256,
            "predecessor_review_path":endpoint.reviewPath,"predecessor_review_sha256":endpoint.reviewSHA256,
            "original_path":original.path,"original_sha256":endpoint.imageSHA256,"original_dimensions":[proposal.sourceWidth,proposal.sourceHeight],
            "normalized_path":normalized.path,"normalized_sha256":endpoint.imageSHA256,"normalized_dimensions":[proposal.profile.width,proposal.profile.height],
            "whole_image_preserved":true,"crop_executed":false,"source_crop_xyxy":[0,0,proposal.sourceWidth,proposal.sourceHeight],
            "source_to_destination_scale":1,"source_to_destination_translation":[0,0],"padding_left_bottom_right_top":[0,0,0,0],
            "algorithm":"byte-identical copy of approved native lossless endpoint; no lossy MP4 re-extraction",
            "semantic_quality_assessed":false,"operator_approval_required":false,"validation_only":false,
            "H3_launched":false,"started_at":ISO8601DateFormatter().string(from:started),"ended_at":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:receiptURL,options:.withoutOverwriting)
        return .init(originalPath:original.path,originalSHA256:endpoint.imageSHA256,normalizedPath:normalized.path,normalizedSHA256:endpoint.imageSHA256,
            extractionReceiptPath:receiptURL.path,extractionReceiptSHA256:try WorkspaceDigest.sha256(receiptURL),
            exactFrameIndex:endpoint.rawIndex,actualPTSValue:Int64(endpoint.rawIndex),actualPTSTimescale:Int32(proposal.sourceFPS),
            originalWidth:proposal.sourceWidth,originalHeight:proposal.sourceHeight,scale:1,translation:[0,0],padding:[0,0,0,0])
    }
}
