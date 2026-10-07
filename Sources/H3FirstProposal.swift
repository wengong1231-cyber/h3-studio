import Foundation
import ImageIO

struct H3FirstInput: Codable, Equatable {
    var originalPath: String
    var originalSHA256: String
    var normalizedPath: String
    var normalizedSHA256: String
    var extractionReceiptPath: String
    var extractionReceiptSHA256: String
    var exactFrameIndex: Int
    var actualPTSValue: Int64
    var actualPTSTimescale: Int32
    var originalWidth: Int
    var originalHeight: Int
    var scale: Double
    var translation: [Double]
    var padding: [Double]
    var sourceKind: String? = nil
}

struct H3FirstPixelReview: Codable, Equatable {
    var schema: String
    var appJobID: UUID
    var proposalSHA256: String
    var sourceMediaSHA256: String
    var sourceFrameIndex: Int
    var originalSHA256: String
    var normalizedSHA256: String
    var promptSHA256: String
    var status: String
    var reviewerKind: String
    var observation: String
    var originalPixelsInspected: Bool
    var normalizedPixelsInspected: Bool
    var promptComparedToActualImage: Bool
    var inspectedAt: Date
    var sourceKind: String? = nil
    var staticBindingSHA256: String? = nil
    var motionReferenceSHA256: [String]? = nil
    var motionReferencePixelsInspected: Bool? = nil
}

struct H3FirstProposal: Codable, Equatable {
    var sourcePath: String
    var sourceSHA256: String
    var snapshotPath: String?
    var proposalID: String
    var shot: Int
    var part: Int
    var sourceMediaPath: String
    var sourceMediaSHA256: String
    var sourceMediaBytes: Int64
    var sourceMediaFrames: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var sourceFPS: Int
    var sourceFrameIndex: Int
    var sourceLocalFrameIndex: Int
    var profile: H3Profile
    var selectedRawStart: Int
    var selectedRawEnd: Int
    var destinationGlobalStart: Int
    var destinationGlobalEnd: Int
    var seed: Int
    var promptPath: String
    var promptSHA256: String
    var prompt: String
    var helperPath: String
    var helperSHA256: String
    var libraryPath: String
    var librarySHA256: String
    var workDirectory: String
    var launchAuthorized: Bool
    var input: H3FirstInput?
    var pixelReview: H3FirstPixelReview?
    var mockScenario: String?
    var queueExecution: H3QueueExecutionSource? = nil
    var shortID: String { String(format: "S%02d", shot) }
    var segment: String { String(format: "s%02d-p%02d", shot, part) }
    var targetFrames: Int { selectedRawEnd - selectedRawStart }
    var nativeDuration: Double { Double(profile.frames) / Double(profile.fps) }
    var isStaticInput: Bool { queueExecution?.staticInput != nil }
    var reviewBindingsMatch: Bool {
        guard let input, let review = pixelReview else { return false }
        let sourceMatches: Bool
        if let binding = queueExecution?.staticInput {
            sourceMatches = review.schema == "jingsheng-App-static-input-review-v1"
                && input.sourceKind == "complete_static_image" && review.sourceKind == "complete_static_image"
                && sourceFrameIndex == -1 && review.sourceFrameIndex == -1
                && review.staticBindingSHA256 == binding.recordSHA256
                && review.motionReferenceSHA256 == binding.motionReferences.map(\.sha256)
                && (binding.motionReferences.isEmpty || review.motionReferencePixelsInspected == true)
        } else { sourceMatches = review.schema == "jingsheng-App-first-frame-review-v1" && review.sourceKind != "complete_static_image" }
        return sourceMatches
            && review.proposalSHA256 == sourceSHA256 && review.sourceMediaSHA256 == sourceMediaSHA256
            && review.sourceFrameIndex == sourceFrameIndex && review.originalSHA256 == input.originalSHA256
            && review.normalizedSHA256 == input.normalizedSHA256 && review.promptSHA256 == promptSHA256
            && ["pass","fail"].contains(review.status) && review.reviewerKind == "assistant"
            && review.originalPixelsInspected && review.normalizedPixelsInspected
            && review.promptComparedToActualImage && (12...4000).contains(review.observation.utf8.count)
    }
    var reviewReady: Bool { reviewBindingsMatch && pixelReview?.status == "pass" }
    static var knownPath: URL {
        AppIdentity.modelStatusRoot.appendingPathComponent("proposals/shot19-App-p01-20261006/App-S19-p01-contract.local.json")
    }
}

struct H3FirstProposalRead {
    var proposal: H3FirstProposal
    var data: Data
}

enum H3FirstProposalReader {
    static func load(_ url: URL, runtime: H3Runtime) throws -> H3FirstProposalRead {
        _ = try H3Files.inside(url.path, runtime.workDirectory + "/proposals")
        return try parse(H3Files.read(url, limit: 1_048_576), sourcePath: url.path, runtime: runtime)
    }
    static func parse(_ data: Data, sourcePath: String, runtime: H3Runtime,requireUserProvenance: Bool = true) throws -> H3FirstProposalRead {
        if let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
           root["schema"] as? String == "jingsheng-App-planned-segment-execution-v1" {
            return try H3QueueExecution.parse(data,sourcePath:sourcePath,runtime:runtime,requireUserProvenance:requireUserProvenance)
        }
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? String == "H3-App-S19-first-segment-preparation-v1",
              let id = root["proposal_id"] as? String, id.hasPrefix("S19-"), id.utf8.count < 160,
              root["shot_number"] as? Int == 19, root["part"] as? Int == 1,
              let authority = root["authorization"] as? [String: Any],
              authority["generation_and_queue_preparation_authorized"] as? Bool == true,
              authority["all_video_operations_must_be_recorded_App_tasks"] as? Bool == true,
              authority["single_GPU_parallelism"] as? Int == 1,
              authority["master_replacement_permitted"] as? Bool == false,
              let baseline = root["baseline"] as? [String: Any],
              let media = root["first_image"] as? [String: Any],
              let native = root["native_generation"] as? [String: Any],
              let profileObject = native["profile"] as? [String: Any],
              let destination = root["destination"] as? [String: Any],
              let post = root["post_generation_App_plan"] as? [String: Any],
              let evidence = root["native_length_evidence"] as? [String: Any],
              let metadata = baseline["container_metadata_read_only_verified"] as? [String: Any],
              let normalization = media["normalization"] as? [String: Any],
              native["mode"] as? String == "first-frame I2V",
              native["model_ref"] as? String == "local/MiniMax-H3-FL2VA-8bit",
              native["lora_ref"] as? String == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",
              native["first_anchor_port"] as? Int == 5, native["last_anchor_port6_connected"] as? Bool == false,
              native["no_repeat_same_image_as_end_anchor"] as? Bool == true,
              native["automatic_retry_count"] as? Int == 0, native["automatic_start"] as? Bool == false,
              native["App_must_create_unique_job_and_history_record"] as? Bool == true,
              native["App_must_check_actual_queue_single_GPU_before_launch"] as? Bool == true,
              media["exact_frame_index_required"] as? Bool == true,
              media["approximate_seek_frame_not_accepted"] as? Bool == true,
              normalization["width"] as? Int == 768, normalization["height"] as? Int == 448,
              normalization["complete_image_required"] as? Bool == true,
              normalization["crop_or_cutout_recomposition_allowed"] as? Bool == false,
              let source = media["source_media_path"] as? String,
              let sourceHash = media["source_media_sha256"] as? String,
              let sourceBytes = baseline["preferred_master_bytes"] as? Int64,
              baseline["preferred_master_path"] as? String == source,
              baseline["preferred_master_sha256"] as? String == sourceHash,
              let frames = metadata["video_frames"] as? Int,
              let width = metadata["width"] as? Int, let height = metadata["height"] as? Int,
              let fps = metadata["fps"] as? Int, fps == 24,
              let index = media["zero_based_global_index"] as? Int, (0..<frames).contains(index),
              let localIndex = media["S19_local_index"] as? Int,
              let seed = native["seed"] as? Int, (0...Int(UInt32.max)).contains(seed),
              let promptPath = native["prompt_path"] as? String, let promptHash = native["prompt_sha256"] as? String,
              let helper = native["helper_path"] as? String, let library = native["library_path"] as? String,
              let helperHash = evidence["helper_sha256"] as? String, let libraryHash = evidence["library_sha256"] as? String,
              native["work_dir"] as? String == runtime.workDirectory,
              native["model_registry_required_cwd"] as? String == runtime.workDirectory,
              post["selected_raw_half_open"] as? [Int] == [0,84], post["raw_frames_expected"] as? Int == 90,
              let global = destination["part1_global_half_open"] as? [Int], global.count == 2, global[1] - global[0] == 84,
              global[0] == index else { throw StudioError.invalid("需要已核 S19 首段提案：完整源帧、A→port5、90帧和单次串行授权。") }
        let profile = try JSONDecoder().decode(H3Profile.self, from: JSONSerialization.data(withJSONObject: profileObject))
        guard profile == .s19First, seed == 841019, sourceBytes > 0, sourceBytes <= 1_073_741_824,
              (1...8192).contains(width), (1...8192).contains(height), (1...20000).contains(frames),
              [sourceHash,promptHash,helperHash,libraryHash].allSatisfy({ ModelStatusReader.isHash($0,length:64) }) else {
            throw StudioError.invalid("S19 尺寸、90帧配置、种子或源文件指纹无效。")
        }
        _ = try H3Files.inside(source,runtime.workDirectory)
        let promptURL = try H3Files.inside(promptPath,runtime.workDirectory + "/proposals")
        _ = try H3Files.safe(helper); _ = try H3Files.safe(library)
        if runtime.mode == .real {
            guard runtime == .real, index == 3248, localIndex == 24, frames == 7229, width == 1920, height == 1080,
                  helper == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Helpers/vpipe",
                  library == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Frameworks/libvpipe.0.dylib",
                  helperHash == H3ABConfigurationReader.helperSHA256, libraryHash == H3ABConfigurationReader.librarySHA256 else {
                throw StudioError.invalid("S19 的母片帧位或原生引擎身份与已核契约不同。")
            }
        } else {
            _ = try H3Files.inside(helper,runtime.workDirectory); _ = try H3Files.inside(library,runtime.workDirectory)
        }
        let promptBytes = try H3Files.read(promptURL,limit:32768)
        guard H3ABConfigurationReader.digest(promptBytes) == promptHash,
              let prompt = String(data:promptBytes,encoding:.utf8), !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw StudioError.invalid("S19 提示词变化或无法读取，未登记任务。")
        }
        return .init(proposal:.init(sourcePath:sourcePath,sourceSHA256:H3ABConfigurationReader.digest(data),proposalID:id,shot:19,part:1,
            sourceMediaPath:source,sourceMediaSHA256:sourceHash,sourceMediaBytes:sourceBytes,sourceMediaFrames:frames,sourceWidth:width,sourceHeight:height,sourceFPS:fps,
            sourceFrameIndex:index,sourceLocalFrameIndex:localIndex,profile:profile,selectedRawStart:0,selectedRawEnd:84,
            destinationGlobalStart:global[0],destinationGlobalEnd:global[1],seed:seed,promptPath:promptPath,promptSHA256:promptHash,prompt:prompt,
            helperPath:helper,helperSHA256:helperHash,libraryPath:library,librarySHA256:libraryHash,workDirectory:runtime.workDirectory,launchAuthorized:true,
            mockScenario:runtime.mode == .mock ? (root["mock_scenario"] as? String) : nil),data:data)
    }
}
