import Foundation
import ImageIO

struct H3StaticInputRecord: Codable, Equatable {
    var schema = "jingsheng-App-static-input-binding-v1"
    var bindingID: UUID
    var appJobID: UUID
    var workspace: String
    var plan: H3QueuePlan
    var primary: H3StaticAsset
    var motionReferences: [H3StaticAsset]
    var prompt: String
    var sourceReference: String
    var createdAt: Date
    var previousJobSHA256: String
    var phaseAllocationPath: String?
    var phaseAllocationSHA256: String?
}

struct H3StaticInputBinding: Codable, Equatable {
    var id: UUID
    var appJobID: UUID
    var directory: String
    var recordSHA256: String
    var primary: H3StaticAsset
    var motionReferences: [H3StaticAsset]
    var promptSHA256: String
    var previousJobSHA256: String
    var phaseAllocationPath: String?
    var phaseAllocationSHA256: String?
    var recordPath: String { directory + "/binding.json" }
    var promptPath: String { directory + "/prompt.txt" }
    var proposalPath: String { directory + "/queue-proposal.json" }
    var reviewPath: String { directory + "/pixel-review.json" }
    var previousJobPath: String { directory + "/previous-job.json" }
    var frozenFiles: [String:String] {
        var result = [recordPath:recordSHA256,promptPath:promptSHA256,previousJobPath:previousJobSHA256,primary.path:primary.sha256]
        for asset in motionReferences { result[asset.path] = asset.sha256 }
        if let path = phaseAllocationPath,let hash = phaseAllocationSHA256 { result[path] = hash }
        return result
    }
    var hasRequiredPhaseAllocation: Bool { primary.shot != 5 || phaseAllocationPath != nil && phaseAllocationSHA256 != nil }
    func validate(source: H3QueueExecutionSource) throws {
        guard source.appJobID == appJobID,source.plan.shot == primary.shot,
              directory == source.appWorkspace + "/h3-config/" + appJobID.uuidString + "/static-inputs/" + id.uuidString,
              motionReferences.count <= 4,Set(([primary] + motionReferences).map(\.id)).count == motionReferences.count+1,
              motionReferences.allSatisfy({ $0.shot == primary.shot }),source.actionRevision == nil else {
            throw StudioError.invalid("静态图绑定不属于当前任务，或把动作参考当作重复首尾锚点。")
        }
        let bytes = try H3Files.read(H3Files.inside(recordPath,directory),limit:262144)
        guard H3ABConfigurationReader.digest(bytes) == recordSHA256 else { throw StudioError.invalid("静态图绑定记录已变化。") }
        let record = try JSONDecoder().decode(H3StaticInputRecord.self,from:bytes)
        guard record.schema == "jingsheng-App-static-input-binding-v1",record.bindingID == id,record.appJobID == appJobID,
              record.workspace == source.appWorkspace,record.plan == source.plan,record.primary == primary,
              record.motionReferences == motionReferences,record.previousJobSHA256 == previousJobSHA256,
              record.phaseAllocationPath == phaseAllocationPath,record.phaseAllocationSHA256 == phaseAllocationSHA256,
              (8...2000).contains(record.sourceReference.utf8.count),
              H3ABConfigurationReader.digest(Data(record.prompt.utf8)) == promptSHA256 else { throw StudioError.invalid("静态来源、任务计划或提示词与冻结记录不同。") }
        for (path,hash) in frozenFiles {
            guard ModelStatusReader.isHash(hash,length:64),H3ABConfigurationReader.digest(try H3Files.read(H3Files.safe(path),limit:50_331_648)) == hash else { throw StudioError.invalid("静态图、参考或历史快照的指纹已变化。") }
        }
        if primary.shot == 5,let path = phaseAllocationPath,let hash = phaseAllocationSHA256 {
            _ = try H3Files.inside(path,source.appWorkspace + "/h3-static-stage-plans")
            guard try WorkspaceDigest.sha256(H3Files.safe(path)) == hash else { throw StudioError.invalid("S05 阶段窗口记录已变化。") }
            let allocation = try JSONDecoder().decode(H3StaticStageAllocation.self,from:H3Files.read(H3Files.safe(path),limit:262144))
            try allocation.validate()
            guard allocation.assignments.contains(where:{ $0.plan == source.plan && $0.asset == primary }) else { throw StudioError.invalid("本段不属于明确登记的 S05 阶段窗口。") }
        }
    }
}

struct H3StaticStageAssignment: Codable, Equatable {
    var plan: H3QueuePlan
    var asset: H3StaticAsset
}
struct H3StaticStageAllocation: Codable, Equatable {
    var schema = "jingsheng-App-static-stage-allocation-v1"
    var sourceReference: String
    var assignments: [H3StaticStageAssignment]
    func validate() throws {
        guard schema == "jingsheng-App-static-stage-allocation-v1",(8...2000).contains(sourceReference.utf8.count) else { throw StudioError.invalid("阶段窗口需要明确的外部分段来源。") }
        try H3StaticStagePlan.validateS05(assignments.map { ($0.plan,$0.asset) })
    }
}

extension H3SourceFrames {
    /// Still image input has no media presentation index or PTS. The -1/0
    /// sentinels in the legacy shared DTO are accepted only with this typed
    /// binding and this receipt schema, and are never displayed as film frames.
    static func prepareStatic(_ proposal: H3FirstProposal,jobID: UUID,control: H3PreparationControl,progress: Progress) async throws -> H3FirstInput {
        guard let source = proposal.queueExecution,let binding = source.staticInput,binding.appJobID == jobID,
              proposal.sourceFrameIndex == -1,proposal.sourceLocalFrameIndex == -1,
              proposal.sourceMediaFrames == 0,proposal.sourceFPS == 0 else { throw StudioError.invalid("没有受支持的静态图类型绑定，未准备首图。") }
        try binding.validate(source:source);try control.check()
        await progress(.init(type:"stage",stage:"核对完整静态图 · SHA 与完整解码"))
        let (data,image) = try binding.primary.readVerified()
        let inputRoot = proposal.workDirectory + "/app-inputs"
        let directory = try H3Files.inside(inputRoot + "/App-source-frames/" + jobID.uuidString + "/static-input-" + binding.id.uuidString,inputRoot)
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw StudioError.invalid("本次静态输入已有预览目录，保留旧图且不覆盖。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original = directory.appendingPathComponent("A-original." + URL(fileURLWithPath:binding.primary.path).pathExtension.lowercased())
        try control.check();try data.write(to:original,options:.withoutOverwriting)
        guard try WorkspaceDigest.sha256(original) == binding.primary.sha256 else { throw StudioError.invalid("完整原图保存后的 SHA 不同。") }
        await progress(.init(type:"prepared_original",path:original.path,message:binding.primary.sha256))
        var referenceReceipts: [[String:Any]] = []
        for (index,asset) in binding.motionReferences.enumerated() {
            try control.check();let (reference,_) = try asset.readVerified()
            let path = directory.appendingPathComponent("motion-reference-\(index+1)." + URL(fileURLWithPath:asset.path).pathExtension.lowercased())
            try reference.write(to:path,options:.withoutOverwriting)
            referenceReceipts.append(["asset_id":asset.id,"stage":asset.stage,"path":path.path,"sha256":asset.sha256,
                "purpose":"identity_and_motion_reference_only","connected_to_port6":false])
            await progress(.init(type:"prepared_reference",path:path.path,message:asset.sha256))
        }
        try control.check();await progress(.init(type:"stage",stage:"完整静态图归一化 · CPU 缩放与补边"))
        let contained = try contain(image),normalized = directory.appendingPathComponent("A-normalized.png")
        try save(contained.image,to:normalized)
        let normalizedHash = try WorkspaceDigest.sha256(normalized)
        await progress(.init(type:"prepared_normalized",path:normalized.path,message:normalizedHash))
        try technicalImage(original.path,hash:binding.primary.sha256,width:image.width,height:image.height)
        try technicalImage(normalized.path,hash:normalizedHash,width:768,height:448)
        try control.check();_ = try binding.primary.readVerified()
        let receipt = directory.appendingPathComponent("static-image-preparation.json")
        let value: [String:Any] = ["schema":"jingsheng-App-static-image-preparation-v1","source_kind":"complete_static_image",
            "app_job_id":jobID.uuidString,"proposal_sha256":proposal.sourceSHA256,"static_binding_sha256":binding.recordSHA256,
            "source_asset_id":binding.primary.id,"source_path":binding.primary.path,"source_sha256":binding.primary.sha256,
            "source_classification":binding.primary.classification,"original_path":original.path,"original_sha256":binding.primary.sha256,
            "original_dimensions":[image.width,image.height],"normalized_path":normalized.path,"normalized_sha256":normalizedHash,
            "normalized_dimensions":[768,448],"source_crop_xyxy":[0,0,image.width,image.height],"source_to_destination_scale":contained.scale,
            "source_to_destination_translation":contained.translation,"padding_left_bottom_right_top":contained.padding,
            "whole_image_preserved":true,"crop_executed":false,"film_frame_identity_claimed":false,
            "algorithm":"CPU vImage high-quality Lanczos contain and opaque black padding",
            "motion_references":referenceReceipts,"motion_references_are_continuous_endpoints":false,
            "semantic_quality_assessed":false,"H3_launched":false,"operator_approval_required":false,
            "ended_at":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:receipt,options:.withoutOverwriting)
        return .init(originalPath:original.path,originalSHA256:binding.primary.sha256,normalizedPath:normalized.path,normalizedSHA256:normalizedHash,
            extractionReceiptPath:receipt.path,extractionReceiptSHA256:try WorkspaceDigest.sha256(receipt),
            exactFrameIndex:-1,actualPTSValue:0,actualPTSTimescale:0,originalWidth:image.width,originalHeight:image.height,
            scale:contained.scale,translation:contained.translation,padding:contained.padding,sourceKind:"complete_static_image")
    }
}
