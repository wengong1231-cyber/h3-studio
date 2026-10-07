import Foundation
import CryptoKit
import ImageIO

// This descriptor is preparation data. Importing it never dispatches a child.
struct H3ImageTechnicalCheck: Codable, Equatable {
    var path: String
    var sha256: String
    var bytes: Int
    var width: Int
    var height: Int
    var decoder = "ImageIO complete image decode"
    var semanticQualityAssessed = false
}
struct H3ABInput: Codable, Equatable {
    var originalPath: String?
    var originalSHA256: String?
    var normalizedPath: String?
    var normalizedSHA256: String?
    var visuallyReviewed: Bool
    var automaticCheck: H3ImageTechnicalCheck?
    var automaticallyValidated: Bool {
        guard let check = automaticCheck else { return false }
        return check.path == normalizedPath && check.sha256 == normalizedSHA256 && check.width == 768 && check.height == 448 && check.bytes > 0
    }
}

struct H3ABConfiguration: Codable, Equatable {
    var sourcePath: String
    var sourceSHA256: String
    var snapshotPath: String?
    var revision: Int = 1
    var first: H3ABInput
    var last: H3ABInput
    var prompt: String?
    var promptSHA256: String?
    var promptReviewed: Bool
    var seed: Int
    var helperPath: String
    var helperSHA256: String
    var libraryPath: String
    var librarySHA256: String
    var workDirectory: String
    var launchAuthorized: Bool
    var blockers: [String]
    var mockScenario: String? = nil
    var proposalID: String? = nil
    var label: String? = nil
    var preprocessingReceiptPath: String? = nil
    var originalProposalSHA256: String? = nil
    var profile: H3Profile { .s41AB }
    var editorialFrames: Int { 72 }
    var nativeDuration: Double { 73.0 / 24 }
    var editorialDuration: Double { 3 }
    var finalAnchorIndex: Int { 72 }
    var finalAnchorPTS: Double { 3 }
    var automaticInputsValidated: Bool { first.automaticallyValidated && last.automaticallyValidated }
    var stage: String { blockers.isEmpty ? "A/B 自动输入检查通过 · 可生成" : "S41 A/B 等待配置 · " + blockers[0] }
    static var knownPath: URL { AppIdentity.modelStatusRoot.appendingPathComponent("app-inputs/shot41-AB-recovery-20261006T020242Z/app-handoff/App-job-proposal.json") }
}

struct H3ABConfigurationRead {
    var configuration: H3ABConfiguration
    var data: Data
}

enum H3ABConfigurationReader {
    static let helperSHA256 = "5d7d2931f943cfd3dd97f5f34eeb9ed3b646907216319ef2cf61791309a74d9d"
    static let librarySHA256 = "a1e8b2ea64d72eaf0b21f513c401a3fc7955aaaa3581c76b32d4827522a94786"
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func imagePath(_ path: String, workDirectory: String, mock: Bool) throws -> URL {
        let url = try H3Files.safe(path)
        let permitted = path.hasPrefix(workDirectory + "/proposals/") || path.hasPrefix(workDirectory + "/app-inputs/") || (!mock && path.hasPrefix(AppIdentity.originalProject + "/assets/"))
        guard permitted, !url.pathComponents.contains(where: { $0.hasPrefix(".") || ["credentials", "secrets"].contains($0.lowercased()) }) else { throw StudioError.invalid("S41 输入必须位于核准的 proposals、app-inputs 或素材目录。") }
        return url
    }
    static func load(_ url: URL, workDirectory: String, mock: Bool = false) throws -> H3ABConfigurationRead {
        _ = try H3Files.safe(url.path)
        guard url.path.hasPrefix(workDirectory + "/proposals/") || url.path.hasPrefix(workDirectory + "/app-inputs/") else { throw StudioError.invalid("S41 配置不在核准的 proposals 或 app-inputs 目录。") }
        return try parse(H3Files.read(url, limit: 1_048_576), sourcePath: url.path, workDirectory: workDirectory, mock: mock)
    }
    static func parse(_ data: Data, sourcePath: String, workDirectory: String, mock: Bool) throws -> H3ABConfigurationRead {
        guard data.count <= 1_048_576, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["jingsheng-App-S41-AB-runtime-contract-v1","jingsheng-App-S41-AB-bound-job-proposal-v2"].contains(root["schema"] as? String ?? ""),
              let task = root["task_descriptor"] as? [String: Any], task["shot_number"] as? Int == 41,
              task["segment_id"] as? String == "s41-p01", task["kind"] as? String == "native_h3_fl2va_first_and_last",
              task["source_configuration_is_per_shot_not_S15_hardcoded"] as? Bool == true,
              let runtime = root["runtime"] as? [String: Any], let ports = root["conditioning_ports"] as? [String: Any],
              let authority = root["execution_authority"] as? [String: Any],
              let bindings = root["local_runtime_bindings"] as? [String: Any],
              let inputs = root["inputs"] as? [String: Any], let prompt = root["prompt"] as? [String: Any],
              let editorial = root["editorial_target"] as? [String: Any],
              let adaptation = root["duration_adaptation_plan"] as? [String: Any] else { throw StudioError.invalid("需要独立 S41 A/B v1 配置；不能用 S15 job 或旧片重投。") }
        let expectedIntegers: [String: Int] = ["width":768, "height":448, "native_frames":73, "native_fps":24, "native_B_anchor_index":72, "video_latent_frames":22, "steps":4, "video_shift":12, "audio_shift":3, "condition_timestep":1, "audio_seconds_setting":0, "memory_cap_mb":12288, "wired_pool_mb":8192]
        guard expectedIntegers.allSatisfy({ runtime[$0.key] as? Int == $0.value }),
              runtime["model_ref"] as? String == "local/MiniMax-H3-FL2VA-8bit", runtime["required_partition"] as? String == "fl2va",
              runtime["lora_ref"] as? String == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema", (runtime["lora_scale"] as? NSNumber)?.doubleValue == 1,
              runtime["i8_gemm"] as? Bool == false, runtime["unload_when_idle"] as? String == "always",
              abs(((runtime["native_duration_seconds"] as? NSNumber)?.doubleValue ?? 0) - 73.0 / 24) < 0.000001,
              (runtime["native_B_anchor_PTS_seconds"] as? NSNumber)?.doubleValue == 3,
              ports["first_iport"] as? Int == 5, ports["last_iport"] as? Int == 6, ports["both_inputs_required"] as? Bool == true,
              ports["first_stage"] as? String == "vae-encode-A", ports["last_stage"] as? String == "vae-encode-B",
              ports["iport7_Ref2VA_reference_rows"] as? Bool == false,
              authority["App_created_executed_logged_task_required"] as? Bool == true, authority["direct_CLI_launch_allowed"] as? Bool == false,
              authority["automatic_retry"] as? Bool == false, authority["old92queue_resume"] as? Bool == false, authority["max_generators"] as? Int == 1,
              editorial["frames"] as? Int == 72, editorial["fps"] as? Int == 24, (editorial["duration_seconds"] as? NSNumber)?.doubleValue == 3,
              adaptation["keep_native_source0_at_target0"] as? Bool == true, adaptation["keep_native_source72_at_target71"] as? Bool == true,
              adaptation["first72_truncation_allowed"] as? Bool == false, adaptation["missing_map_blocks_export"] as? Bool == true,
              bindings["registry_working_directory"] as? String == workDirectory,
              let helper = bindings["helper_path"] as? String, let helperHash = bindings["helper_sha256"] as? String,
              let library = bindings["native_library_path"] as? String, let libraryHash = bindings["native_library_sha256"] as? String,
              let seed = task["seed_proposal"] as? Int, (0...Int(UInt32.max)).contains(seed) else { throw StudioError.invalid("S41 的 73 帧、A/B 端口、模型、时长或串行资源配置不匹配。") }
        _ = try H3Files.safe(workDirectory); _ = try H3Files.safe(helper); _ = try H3Files.safe(library)
        if !mock {
            guard workDirectory == AppIdentity.modelStatusRoot.path,
                  helper == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Helpers/vpipe", helperHash == helperSHA256,
                  library == AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents/Frameworks/libvpipe.0.dylib", libraryHash == librarySHA256 else { throw StudioError.invalid("S41 原生引擎身份与父任务已核版本不匹配。") }
        } else { _ = try H3Files.inside(helper, workDirectory); _ = try H3Files.inside(library, workDirectory) }
        var blockers: [String] = []
        func input(_ name: String) throws -> H3ABInput {
            guard let value = inputs[name] as? [String: Any] else { throw StudioError.invalid("S41 必须分别声明 A 首图和 B 末图。") }
            var result = H3ABInput(originalPath:value["path"] as? String, originalSHA256:value["sha256"] as? String,
                normalizedPath:value["normalized_path"] as? String, normalizedSHA256:value["normalized_sha256"] as? String,
                visuallyReviewed:value["normalized_visual_review_passed"] as? Bool == true)
            for (path, hash, normalized) in [(result.originalPath,result.originalSHA256,false),(result.normalizedPath,result.normalizedSHA256,true)] {
                guard let path, let hash else { blockers.append(name + (normalized ? " 的 768×448 图与指纹未齐" : " 的最终原图与指纹未齐")); continue }
                guard ModelStatusReader.isHash(hash,length:64) else { throw StudioError.invalid(name + " 图指纹无效。") }
                let imageURL = try imagePath(path, workDirectory:workDirectory, mock:mock)
                let bytes = try H3Files.read(imageURL,limit:50_331_648)
                guard digest(bytes) == hash else { throw StudioError.invalid(name + " 图已变化；当前文件与核准指纹不同。") }
                guard let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...8192).contains(width),(1...8192).contains(height), !normalized || (width == 768 && height == 448) else { throw StudioError.invalid(name + " 图不是有效图片或归一尺寸不是 768×448。") }
                if normalized {
                    guard CGImageSourceGetStatus(image) == .statusComplete,
                          CGImageSourceGetStatusAtIndex(image,0) == .statusComplete,
                          let decoded = CGImageSourceCreateImageAtIndex(image,0,[kCGImageSourceShouldCache:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
                          decoded.width == 768, decoded.height == 448 else {
                        throw StudioError.invalid(name + " 归一图不能完整解码，自动检查未通过。")
                    }
                    result.automaticCheck = .init(path:path,sha256:hash,bytes:bytes.count,width:decoded.width,height:decoded.height)
                }
            }
            return result
        }
        let first = try input("A"), last = try input("B")
        if let a = first.normalizedSHA256, let b = last.normalizedSHA256, a == b { throw StudioError.invalid("新 S41 必须使用独立水下 A 和海上 B，不能复制同一张旧 S15 图。") }
        let isBoundProposal = root["schema"] as? String == "jingsheng-App-S41-AB-bound-job-proposal-v2"
        let userAuthorization = root["user_authorization"] as? [String:Any]
        let proposalAuthorized = isBoundProposal && userAuthorization?["user_authorized_execution_via_App"] as? Bool == true && userAuthorization?["direct_CLI_execution_authorized"] as? Bool == false &&
            (inputs["A"] as? [String:Any])?["source_user_approved"] as? Bool == true && (inputs["B"] as? [String:Any])?["source_user_approved"] as? Bool == true
        if isBoundProposal && !mock {
            guard root["stable_job_id"] as? String == "app-shot41-AB-recovery-20261006T020242Z",
                  first.originalSHA256 == "d85f9bdf28a11947d503e4baa5c8a1a4c9e5bd773cbfe61e194d227898486a70",
                  last.originalSHA256 == "889d161c489b07e3120ffaaa8c6fe5c38bfced8f41ed9541db804a5976fdd9d8",
                  (inputs["A"] as? [String:Any])?["library_file_id"] as? String == "libfile_3c4c2eef77f08191ae79f1bc5c820f36",
                  (inputs["B"] as? [String:Any])?["library_file_id"] as? String == "libfile_211c629ecbec81918553e78354b7b2b4",
                  let pipelinePath = bindings["pipeline_path"] as? String,let pipelineHash = bindings["pipeline_sha256"] as? String else { throw StudioError.invalid("S41 A v2 / B 收势 v3 的身份或已核管线缺失。") }
            _ = try H3Files.inside(pipelinePath,workDirectory + "/app-inputs")
            guard try WorkspaceDigest.sha256(H3Files.safe(pipelinePath)) == pipelineHash else { throw StudioError.invalid("S41 父任务准备的管线文件发生变化。") }
        }
        let text = prompt["text"] as? String, promptHash = prompt["sha256"] as? String, reviewed = prompt["reviewed"] as? Bool == true || (proposalAuthorized && prompt["status"] as? String == "bound_to_confirmed_Av2_and_Brecoveryv3")
        if let text, let promptHash {
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count <= 80_000, digest(Data(text.utf8)) == promptHash else { throw StudioError.invalid("S41 提示词为空、过长或指纹不符。") }
        } else { blockers.append("S41 专用提示词与指纹未齐") }
        if !reviewed { blockers.append("S41 专用提示词尚未核对") }
        let launchAuthorized = root["ready_for_launch"] as? Bool == true || proposalAuthorized
        if !launchAuthorized { blockers.append("最终素材配置尚未放行") }
        let scenario = root["mock_scenario"] as? String
        guard scenario == nil || (mock && ["normal","runner_failure","wrong_frames","missing_output","cancel_after_output","slow_generation"].contains(scenario!)) else { throw StudioError.invalid("真实 S41 不接受测试故障注入。") }
        return H3ABConfigurationRead(configuration:.init(sourcePath:sourcePath,sourceSHA256:digest(data),first:first,last:last,prompt:text,promptSHA256:promptHash,promptReviewed:reviewed,seed:seed,helperPath:helper,helperSHA256:helperHash,libraryPath:library,librarySHA256:libraryHash,workDirectory:workDirectory,launchAuthorized:launchAuthorized,blockers:blockers,mockScenario:scenario,proposalID:root["stable_job_id"] as? String,label:task["label"] as? String,preprocessingReceiptPath:root["App_preprocessing_receipt"] as? String,originalProposalSHA256:root["App_original_proposal_sha256"] as? String),data:data)
    }
}

struct H3FrameMap73To72: Codable, Equatable {
    var droppedSourceFrame: Int
    var outputToSource: [Int]
    init(dropping index: Int) throws {
        guard (1...71).contains(index) else { throw StudioError.invalid("只能删除一张内部帧，必须保留 raw0 和 raw72。") }
        droppedSourceFrame = index; outputToSource = (0..<73).filter { $0 != index }
    }
    func validate() throws {
        guard (1...71).contains(droppedSourceFrame), outputToSource == (0..<73).filter({ $0 != droppedSourceFrame }),
              outputToSource.count == 72,outputToSource.first == 0,outputToSource.last == 72 else { throw StudioError.invalid("73→72 导出映射缺失或不正确；禁止截去最后海上锚点。") }
    }
}
