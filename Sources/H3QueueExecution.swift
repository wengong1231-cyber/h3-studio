import Foundation
import AVFoundation

struct H3QueueEndpointReview: Codable, Equatable {
    var schema = "jingsheng-App-selected-endpoint-review-v1"
    var appJobID: UUID
    var requestID: String
    var nativeJobSHA256: String
    var clipSHA256: String
    var reportSHA256: String
    var selectedRawHalfOpen: [Int]
    var endpointRawIndex: Int
    var endpointSHA256: String
    var status: String
    var reviewerKind: String
    var userEvidenceID: String
    var selectedWindowViewed: Bool
    var endpointPixelsViewed: Bool
    var observation: String
    var reviewedAt: Date
    var knownVisualRisks: [String]? = nil
    var acceptanceSource: String? = nil
    var provenance: H3AcceptanceProvenance? = nil
    var actionRevisionNumber: Int? = nil
    var acceptancePromptSHA256: String? = nil
    var acceptanceStaticBindingSHA256: String? = nil
}

struct H3QueueEndpointBinding: Codable, Equatable {
    var appJobID: UUID
    var requestID: String
    var jobPath: String
    var jobSHA256: String
    var profile: H3Profile
    var clipPath: String
    var clipSHA256: String
    var reportPath: String
    var reportSHA256: String
    var imagePath: String
    var imageSHA256: String
    var rawIndex: Int
    var reviewPath: String
    var reviewSHA256: String
    var frozenFiles: [String:String] {
        [jobPath:jobSHA256,clipPath:clipSHA256,reportPath:reportSHA256,imagePath:imageSHA256,reviewPath:reviewSHA256]
    }
}

struct H3QueueExecutionSource: Codable, Equatable {
    var appJobID: UUID
    var appWorkspace: String
    var plan: H3QueuePlan
    var sourceBytes: Int64
    var sourceFrames: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var sourceFPS: Int
    var endpoint: H3QueueEndpointBinding?
    var actionRevision: H3ActionRevision? = nil
    var staticInput: H3StaticInputBinding? = nil
    var receiptRebind: H3ReceiptRebind? = nil
    var frozenFiles: [String:String] {
        var files = endpoint?.frozenFiles ?? [:]
        if let path = plan.manifestSnapshotPath { files[path] = plan.manifestSHA256 }
        for (path,hash) in actionRevision?.frozenFiles ?? [:] { files[path] = hash }
        for (path,hash) in staticInput?.frozenFiles ?? [:] { files[path] = hash }
        for (path,hash) in receiptRebind?.frozenFiles ?? [:] { files[path] = hash }
        return files
    }
}

struct H3QueueExecutionDescriptor: Codable {
    var schema = "jingsheng-App-planned-segment-execution-v1"
    var source: H3QueueExecutionSource
    var mockScenario: String?
}

struct H3QueueDependencyUnavailable: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum H3QueueExecution {
    static func reviewURL(workspace: URL,id: UUID) -> URL {
        workspace.appendingPathComponent("h3-queue-reviews/" + id.uuidString + "/endpoint-review.json")
    }
    static func manifest(_ source: H3QueueExecutionSource,runtime: H3Runtime) throws -> (H3QueuePlan,[String:Any],[ShotJob]) {
        guard let path = source.plan.manifestSnapshotPath else { throw StudioError.invalid("队列缺少不可变清单快照。") }
        _ = try H3Files.inside(path,source.appWorkspace + "/h3-queue")
        let data = try H3Files.read(H3Files.safe(path),limit:2_097_152)
        guard H3ABConfigurationReader.digest(data) == source.plan.manifestSHA256 else { throw StudioError.invalid("队列清单快照指纹变化。") }
        let read = try H3QueueReader.parse(data,runtime:runtime)
        guard var expected = read.jobs.first(where:{ $0.h3QueuePlan?.requestID == source.plan.requestID })?.h3QueuePlan else {
            throw StudioError.invalid("清单没有该段请求身份。")
        }
        expected.manifestSnapshotPath = path
        guard expected == source.plan else { throw StudioError.invalid("该段配置不是已核清单参数。") }
        return (expected,try JSONSerialization.jsonObject(with:data) as! [String:Any],read.jobs)
    }
    static func validateEndpoint(_ endpoint: H3QueueEndpointBinding,source: H3QueueExecutionSource,runtime: H3Runtime,jobs: [ShotJob],requireUserProvenance: Bool = true) throws {
        let plan = source.plan
        guard plan.dependencyRequestID == endpoint.requestID,plan.dependencyRawIndex == endpoint.rawIndex,
              let previous = jobs.first(where:{ $0.h3QueuePlan?.requestID == endpoint.requestID })?.h3QueuePlan,
              previous.shot == plan.shot,previous.part + 1 == plan.part,previous.profile == endpoint.profile,
              previous.selectedRawEnd - 1 == endpoint.rawIndex else { throw StudioError.invalid("续段不是本镜前段的选择窗口端点。") }
        _ = try H3Files.inside(endpoint.jobPath,runtime.workDirectory + "/candidates")
        _ = try H3Files.inside(endpoint.reviewPath,source.appWorkspace + "/h3-queue-reviews")
        guard endpoint.reviewPath == reviewURL(workspace:URL(fileURLWithPath:source.appWorkspace),id:endpoint.appJobID).path else {
            throw StudioError.invalid("前段审核回执路径不属于前段 App 身份。")
        }
        for (path,hash) in endpoint.frozenFiles {
            guard ModelStatusReader.isHash(hash,length:64),try WorkspaceDigest.sha256(H3Files.safe(path)) == hash else {
                throw StudioError.invalid("前段视频、端点、任务或审核回执指纹变化。")
            }
        }
        let native = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(H3Files.safe(endpoint.jobPath)))
        guard let owner = native.app_first_task,owner.appJobID == endpoint.appJobID,owner.appWorkspace == source.appWorkspace,
              owner.proposal.shot == previous.shot,owner.proposal.part == previous.part,
              owner.proposal.selectedRawStart == previous.selectedRawStart,owner.proposal.selectedRawEnd == previous.selectedRawEnd,
              native.profile == previous.profile,native.clip_path == endpoint.clipPath,
              endpoint.reportPath == native.output_dir + "/technical-validation.json" else {
            throw StudioError.invalid("前段输出没有绑定本 App 的前段任务。")
        }
        // Parts strictly decrease before recursively validating a predecessor.
        _ = try H3FirstTaskBinding.load(H3Files.safe(endpoint.jobPath),runtime:runtime,requireFresh:false,allowHistoricalAcceptance:true)
        if requireUserProvenance,try H3VideoRejectionReader.blocksContinuation(workspace:URL(fileURLWithPath:source.appWorkspace),id:endpoint.appJobID,nativeSHA256:endpoint.jobSHA256,clipSHA256:endpoint.clipSHA256) {
            throw H3QueueDependencyUnavailable(message:"前段候选已拒绝，原验收和旧端点不能放行本段。")
        }
        let report = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(endpoint.reportPath))) as! [String:Any]
        guard report["status"] as? String == "technical_pass",report["app_job_id"] as? String == endpoint.appJobID.uuidString,
              report["clip_sha256"] as? String == endpoint.clipSHA256,report["native_exit_code"] as? Int == 0,
              report["decoded_video_frames"] as? Int == previous.profile.frames,
              report["native_lossless_frames"] as? Int == previous.profile.frames,
              report["selected_raw_half_open"] as? [Int] == [previous.selectedRawStart,previous.selectedRawEnd],
              report["continuation_endpoint_raw_index"] as? Int == endpoint.rawIndex,
              report["continuation_endpoint_sha256"] as? String == endpoint.imageSHA256,
              let frames = report["lossless_frame_receipts"] as? [[String:Any]],
              frames.count == previous.profile.frames,
              let frame = frames.first(where:{ $0["source_index"] as? Int == endpoint.rawIndex }),
              frame["sha256"] as? String == endpoint.imageSHA256,
              let name = frame["file"] as? String,name == String(format:"frame-%04d.png",endpoint.rawIndex),
              endpoint.imagePath == native.output_dir + "/record/lossless-frames/" + name else {
            throw StudioError.invalid("前段技术回执没有确认本次精确端点。")
        }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let review = try decoder.decode(H3QueueEndpointReview.self,from:H3Files.read(H3Files.safe(endpoint.reviewPath),limit:16384))
        guard review.schema == "jingsheng-App-selected-endpoint-review-v1",review.status == "pass",
              review.appJobID == endpoint.appJobID,review.requestID == endpoint.requestID,
              review.nativeJobSHA256 == endpoint.jobSHA256,review.clipSHA256 == endpoint.clipSHA256,
              review.reportSHA256 == endpoint.reportSHA256,review.endpointRawIndex == endpoint.rawIndex,
              review.endpointSHA256 == endpoint.imageSHA256,
              review.selectedRawHalfOpen == [previous.selectedRawStart,previous.selectedRawEnd],
              (review.selectedWindowViewed && review.endpointPixelsViewed || review.provenance?.declaresProductAcceptance == true),
              (12...4000).contains(review.observation.utf8.count),
              try (!requireUserProvenance || H3AcceptanceAuthority.valid(review,workspace:URL(fileURLWithPath:source.appWorkspace),runtime:runtime,requireContinuation:true,
                  successorAppJobID:source.appJobID,successorRequestID:source.plan.requestID)) else {
            throw StudioError.invalid("前段画面审核未绑定当前视频、选择窗口和端点；技术通过不能代替画面认可。")
        }
        try H3SourceFrames.technicalImage(endpoint.imagePath,hash:endpoint.imageSHA256,width:previous.profile.width,height:previous.profile.height)
    }
    static func descriptor(job: ShotJob,predecessor: ShotJob?,workspace: URL,runtime: H3Runtime,mockScenario: String? = nil) throws -> Data {
        guard let plan = job.h3QueuePlan,job.externalHistory == nil,job.status.isPending,job.attempts.isEmpty,
              mockScenario == nil || runtime.mode == .mock else { throw StudioError.invalid("只允许未领取的 App 队列段。") }
        var source = H3QueueExecutionSource(appJobID:job.id,appWorkspace:workspace.path,plan:plan,
            sourceBytes:0,sourceFrames:0,sourceWidth:0,sourceHeight:0,sourceFPS:24)
        source.staticInput = job.h3StaticBinding
        let (_,object,jobs) = try manifest(source,runtime:runtime)
        if let request = plan.dependencyRequestID {
            guard let predecessor,predecessor.supersededBy == nil,predecessor.h3QueuePlan?.requestID == request,predecessor.status == .completed,
                  let outcome = predecessor.h3Outcome,outcome.technicalPass,let binding = predecessor.h3Binding,
                  binding.appTaskID == predecessor.id else {
                throw H3QueueDependencyUnavailable(message:"等待前段完成技术检查与画面审核。")
            }
            let review = reviewURL(workspace:workspace,id:predecessor.id)
            guard FileManager.default.fileExists(atPath:review.path) else {
                throw H3QueueDependencyUnavailable(message:"前段技术通过，等待该段画面及所选端点的明确审核；未自动采用端点。")
            }
            let report = try JSONSerialization.jsonObject(with:H3Files.read(H3Files.safe(outcome.reportPath))) as! [String:Any]
            guard let raw = plan.dependencyRawIndex,let frames = report["lossless_frame_receipts"] as? [[String:Any]],
                  let frame = frames.first(where:{ $0["source_index"] as? Int == raw }),
                  let name = frame["file"] as? String,let hash = frame["sha256"] as? String,
                  let clipHash = report["clip_sha256"] as? String else { throw StudioError.invalid("前段缺少端点逐帧回执。") }
            source.endpoint = .init(appJobID:predecessor.id,requestID:request,jobPath:binding.jobPath,jobSHA256:binding.jobSHA256,
                profile:binding.profile,clipPath:binding.clipPath,clipSHA256:clipHash,
                reportPath:outcome.reportPath,reportSHA256:try WorkspaceDigest.sha256(H3Files.safe(outcome.reportPath)),
                imagePath:binding.outputDirectory + "/record/lossless-frames/" + name,imageSHA256:hash,rawIndex:raw,
                reviewPath:review.path,reviewSHA256:try WorkspaceDigest.sha256(review))
            source.sourceBytes = Int64(try H3Files.safe(binding.clipPath).resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
            source.sourceFrames = binding.profile.frames;source.sourceWidth = binding.profile.width;source.sourceHeight = binding.profile.height
            try validateEndpoint(source.endpoint!,source:source,runtime:runtime,jobs:jobs)
        } else if source.staticInput == nil {
            guard let master = object["effective_current_master"] as? [String:Any],
                  let path = master["path"] as? String,path == plan.sourceMediaPath,
                  let bytes = master["bytes"] as? Int64,let frames = master["video_frames"] as? Int else {
                throw StudioError.invalid("独立首段缺少已核母片信息。")
            }
            let asset = AVURLAsset(url:try H3Files.inside(path,runtime.workDirectory))
            guard let track = asset.tracks(withMediaType:.video).first else { throw StudioError.invalid("母片缺少视频轨道。") }
            source.sourceBytes = bytes;source.sourceFrames = frames
            source.sourceWidth = Int(track.naturalSize.width);source.sourceHeight = Int(track.naturalSize.height)
        }
        if let input = source.staticInput {
            source.sourceBytes = Int64(input.primary.bytes);source.sourceFrames = 0
            source.sourceWidth = input.primary.width;source.sourceHeight = input.primary.height;source.sourceFPS = 0
            try input.validate(source:source)
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        return try encoder.encode(H3QueueExecutionDescriptor(source:source,mockScenario:mockScenario))
    }
    static func parse(_ data: Data,sourcePath: String,runtime: H3Runtime,requireUserProvenance: Bool = true) throws -> H3FirstProposalRead {
        let descriptor = try JSONDecoder().decode(H3QueueExecutionDescriptor.self,from:data),source = descriptor.source,plan = source.plan
        guard descriptor.schema == "jingsheng-App-planned-segment-execution-v1",
              (1...8192).contains(source.sourceWidth),(1...8192).contains(source.sourceHeight),
              (1...1_073_741_824).contains(source.sourceBytes),
              descriptor.mockScenario == nil || runtime.mode == .mock else { throw StudioError.invalid("队列执行描述无效。") }
        guard source.staticInput != nil ? source.sourceFrames == 0 && source.sourceFPS == 0 :
                source.sourceFPS == 24 && (1...20000).contains(source.sourceFrames) else { throw StudioError.invalid("静态图片与视频帧来源类型不能混用。") }
        _ = try H3Files.safe(source.appWorkspace)
        let ownedPath = source.receiptRebind?.proposalPath ?? source.staticInput?.proposalPath ?? source.actionRevision?.proposalPath ?? (source.appWorkspace + "/h3-config/" + source.appJobID.uuidString + "/queue-proposal.json")
        guard sourcePath == ownedPath else {
            throw StudioError.invalid("队列执行描述不属于 App 任务。")
        }
        let (_,object,jobs) = try manifest(source,runtime:runtime)
        if let rebind = source.receiptRebind { try rebind.validate(source:source,runtime:runtime) }
        if let revision = source.actionRevision { try revision.validate(source:source,runtime:runtime,requireUserProvenance:requireUserProvenance) }
        let path: String,hash: String,index: Int
        if let endpoint = source.endpoint { try validateEndpoint(endpoint,source:source,runtime:runtime,jobs:jobs,requireUserProvenance:requireUserProvenance) }
        if let input = source.staticInput {
            try input.validate(source:source)
            guard source.sourceBytes == Int64(input.primary.bytes),source.sourceWidth == input.primary.width,
                  source.sourceHeight == input.primary.height,
                  plan.dependencyRequestID == nil || source.endpoint != nil else { throw StudioError.invalid("静态首图仍须保留已核前段依赖，不能绕过接续条件。") }
            path = input.primary.path;hash = input.primary.sha256;index = -1
        } else if let endpoint = source.endpoint {
            path = endpoint.clipPath;hash = endpoint.clipSHA256;index = endpoint.rawIndex
            guard source.sourceFrames == endpoint.profile.frames,source.sourceWidth == endpoint.profile.width,
                  source.sourceHeight == endpoint.profile.height else { throw StudioError.invalid("端点原生配置不同。") }
        } else {
            guard plan.dependencyRequestID == nil,let master = object["effective_current_master"] as? [String:Any],
                  let media = plan.sourceMediaPath,let sha = plan.sourceMediaSHA256,let frame = plan.sourceGlobalFrameIndex,
                  master["path"] as? String == media,master["sha256"] as? String == sha,
                  master["bytes"] as? Int64 == source.sourceBytes,master["video_frames"] as? Int == source.sourceFrames,
                  (0..<source.sourceFrames).contains(frame) else { throw StudioError.invalid("母片来源和清单不一致。") }
            path = media;hash = sha;index = frame
        }
        let promptPath = source.staticInput?.promptPath ?? source.actionRevision?.promptPath ?? plan.promptPath
        let promptSHA256 = source.staticInput?.promptSHA256 ?? source.actionRevision?.promptSHA256 ?? plan.promptSHA256
        let promptRoot = source.staticInput?.directory ?? source.actionRevision?.directory ?? (runtime.workDirectory + "/proposals")
        let promptBytes = try H3Files.read(H3Files.inside(promptPath,promptRoot),limit:32768)
        guard H3ABConfigurationReader.digest(promptBytes) == promptSHA256,let prompt = String(data:promptBytes,encoding:.utf8) else {
            throw StudioError.invalid("当前段提示词指纹不同。")
        }
        let helper = runtime.mode == .mock ? runtime.workDirectory + "/mock-helper" : AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Helpers/vpipe"
        let library = runtime.mode == .mock ? runtime.workDirectory + "/mock-library" : AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Frameworks/libvpipe.0.dylib"
        let helperHash = runtime.mode == .mock ? try WorkspaceDigest.sha256(H3Files.safe(helper)) : H3ABConfigurationReader.helperSHA256
        let libraryHash = runtime.mode == .mock ? try WorkspaceDigest.sha256(H3Files.safe(library)) : H3ABConfigurationReader.librarySHA256
        return .init(proposal:.init(sourcePath:sourcePath,sourceSHA256:H3ABConfigurationReader.digest(data),
            proposalID:plan.requestID,shot:plan.shot,part:plan.part,sourceMediaPath:path,sourceMediaSHA256:hash,
            sourceMediaBytes:source.sourceBytes,sourceMediaFrames:source.sourceFrames,sourceWidth:source.sourceWidth,sourceHeight:source.sourceHeight,
            sourceFPS:source.sourceFPS,sourceFrameIndex:index,sourceLocalFrameIndex:source.staticInput != nil ? -1 : source.endpoint?.rawIndex ?? 0,profile:plan.profile,
            selectedRawStart:plan.selectedRawStart,selectedRawEnd:plan.selectedRawEnd,
            destinationGlobalStart:plan.destinationStart,destinationGlobalEnd:plan.destinationEnd,seed:plan.seed,
            promptPath:promptPath,promptSHA256:promptSHA256,prompt:prompt,helperPath:helper,helperSHA256:helperHash,
            libraryPath:library,librarySHA256:libraryHash,workDirectory:runtime.workDirectory,launchAuthorized:source.staticInput?.hasRequiredPhaseAllocation ?? true,
            mockScenario:descriptor.mockScenario,queueExecution:source),data:data)
    }
}
