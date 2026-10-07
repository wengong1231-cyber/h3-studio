import Foundation

enum ModelCheckState: String, Codable, Sendable {
    case unknown, pending, running, verified, failed, mismatch, stale
    var isConfirmed: Bool { self == .verified || self == .running }
}
struct ModelStateDetail: Codable, Sendable {
    var state: ModelCheckState
    var label: String
    var note: String
    var verifiedAt: Date?
    static func unknown(_ label: String, _ note: String, verifiedAt: Date? = nil) -> Self {
        Self(state: .unknown, label: label, note: note, verifiedAt: verifiedAt)
    }
}
struct ModelPreparationVerification: Codable, Sendable {
    var download: ModelStateDetail
    var quantization: ModelStateDetail
    var runtime: ModelStateDetail
    var checkedAt: Date
    var nextGenerationAuthorized: Bool?
}

struct DownloadFileIdentity: Decodable, Sendable {
    var relative_path: String
    var size: Int64
    var repo: String
    var revision: String
    var remote_path: String
    var sha256: String?
    var git_blob_sha1: String?
    func matches(_ file: DownloadFileStatus) -> Bool {
        relative_path == file.relative_path && size == file.size && repo == file.repo && revision == file.revision && remote_path == file.remote_path &&
        (sha256 == nil || sha256 == file.sha256) && (git_blob_sha1 == nil || git_blob_sha1 == file.git_blob_sha1)
    }
}
struct DownloadManifest: Decodable, Sendable {
    var version: Int
    var model_dir: String
    var original_quantized_model_key: String
    var lora_key: String
    var total_bytes: Int64
    var files: [DownloadFileIdentity]
    static func parse(_ data: Data, root: URL) throws -> Self {
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw ModelStatusReadFailure.invalidManifest }
        guard value.version == 1, value.model_dir == root.appendingPathComponent("models").path,
              value.original_quantized_model_key == ModelValidationContext.modelKey, value.lora_key == ModelValidationContext.loraKey,
              (1...100).contains(value.files.count), value.total_bytes > 0,
              Set(value.files.map(\.relative_path)).count == value.files.count else { throw ModelStatusReadFailure.invalidManifest }
        var sum: Int64 = 0
        for file in value.files {
            let next = sum.addingReportingOverflow(file.size)
            guard file.size > 0, !next.overflow, ModelStatusReader.safeRelative(file.relative_path),
                  ModelStatusReader.safeRelative(file.remote_path), !file.repo.isEmpty,
                  ModelStatusReader.isHash(file.revision, length: 40),
                  file.sha256.map({ ModelStatusReader.isHash($0, length: 64) }) ?? (file.git_blob_sha1.map { ModelStatusReader.isHash($0, length: 40) } == true) else {
                throw ModelStatusReadFailure.invalidManifest
            }
            sum = next.partialValue
        }
        guard sum == value.total_bytes else { throw ModelStatusReadFailure.invalidManifest }
        return value
    }
    func matches(_ snapshot: DownloadSnapshot) -> Bool {
        snapshot.version == version && snapshot.model_dir == model_dir && snapshot.files.count == files.count &&
        Set(snapshot.files.map(\.relative_path)).count == files.count && files.allSatisfy { identity in
            snapshot.files.first(where: { $0.relative_path == identity.relative_path }).map(identity.matches) == true
        }
    }
}

struct ModelValidationContext: Sendable {
    static let modelKey = "local/MiniMax-H3-FL2VA-8bit"
    static let loraKey = "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema"
    static let helperHash = "5d7d2931f943cfd3dd97f5f34eeb9ed3b646907216319ef2cf61791309a74d9d"
    static let libraryHash = "a1e8b2ea64d72eaf0b21f513c401a3fc7955aaaa3581c76b32d4827522a94786"
    var helper: URL?
    var library: URL?
    var helperSHA256: String
    var librarySHA256: String
    // These are the explicitly inspected restoration revisions, not a moving
    // upstream version. A different source requires a new approved contract.
    var pinnedSourceSignatures: [String: String]?
    static func approved(for root: URL) -> Self {
        guard root == AppIdentity.modelStatusRoot else {
            return Self(helper: nil, library: nil, helperSHA256: helperHash, librarySHA256: libraryHash)
        }
        let base = URL(fileURLWithPath: AppIdentity.originalProject + "/local-video-tools/Vpipe Manager.app/Contents")
        let names = ["diffusion_models/minimax_h3_fl2va_bf16.safetensors", "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors", "vae/minimax_h3_video_vae_fp16.safetensors", "vae/minimax_h3_audio_vae_fp32.safetensors", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "LICENSE"]
        let hashes = ["907d4add438438ec1544f5240c3b38532ed934fe6be75677a6bbda2a6fdd6182", "600d567f6a9629c8574e8e7041b199bdd9c59a986afa7906910a81919610607d", "7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522", "8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48", "c6cc1014128b19d1fc46b1d30a23e3b1d35db421", "204d76f78dac6dedc820418c30bf01145de78a21", "c389b45855337ccec8ddeb389f4fe902abcd0b19"]
        var signatures: [String: String] = [:]
        for index in names.indices {
            let revision = index < 4 ? "4cc1d817b6184899b41293954329f576cb5ae86b" : "42ed227ee7df40d41602854ae760620d6eb651fe"
            let repo = index < 4 ? "Comfy-Org/MiniMax-H3" : "MiniMaxAI/MiniMax-H3"
            signatures["Comfy-Org/MiniMax-H3/" + names[index]] = repo + ":" + revision + ":" + hashes[index]
        }
        signatures["larryvrh/MiniMax-H3-Turbo-Lora/minimax_h3_turbo_v4_step600_ema.safetensors"] = "larryvrh/MiniMax-H3-Turbo-Lora:43a74557ac3f6539db8e0f2a959d03feb7a81480:5f3a626cd72c93a8b9318d6760c510bc5092d2ab13aaba1f932c5bab07a416d3"
        return Self(helper: base.appendingPathComponent("Helpers/vpipe"), library: base.appendingPathComponent("Frameworks/libvpipe.0.dylib"), helperSHA256: helperHash, librarySHA256: libraryHash, pinnedSourceSignatures: signatures)
    }
    func accepts(_ manifest: DownloadManifest) -> Bool {
        guard let pinnedSourceSignatures else { return true }
        let actual = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relative_path, $0.repo + ":" + $0.revision + ":" + ($0.sha256 ?? $0.git_blob_sha1 ?? "")) })
        return actual == pinnedSourceSignatures
    }
}

enum ModelPreparationVerifier {
    private struct CheckFailure: Error { var note: String }
    private static func require(_ passed: Bool, _ note: String) throws {
        if !passed { throw CheckFailure(note: note) }
    }
    private static func object(_ url: URL) throws -> [String: Any] { try ModelStatusReader.object(url) }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func download(_ manifest: DownloadManifest, _ snapshot: DownloadSnapshot, root: URL, now: Date) -> ModelStateDetail {
        if snapshot.status == "failed" { return .init(state: .failed, label: "下载上报失败", note: "保留实际字节与已校验文件") }
        if snapshot.isDownloading {
            return .init(state: snapshot.stale(at: now) ? .stale : .running, label: snapshot.stale(at: now) ? "下载心跳待更新" : "下载中（实际字节）", note: "进行中的下载每 45 秒核对心跳")
        }
        guard snapshot.isVerifiedTerminal else { return .unknown("下载终态待确认", "来源未提供已校验的完成终态") }
        guard let verifiedAt = snapshot.date, verifiedAt.timeIntervalSince(now) <= 45,
              snapshot.downloaded_bytes == manifest.total_bytes, snapshot.verified_files == manifest.files.count,
              snapshot.files.allSatisfy({ $0.state == "verified" && $0.publisher_checksum_verified == true && $0.downloaded_bytes == $0.size }) else {
            return .init(state: .mismatch, label: "下载完成证据不一致", note: "100% 字节不能代替逐文件校验完成")
        }
        do {
            for file in manifest.files { try ModelStatusReader.requireFile(root.appendingPathComponent("models/" + file.relative_path), bytes: file.size) }
            return .init(state: .verified, label: "下载已完成并校验", note: "清单版本、来源指纹、\(manifest.files.count) 个文件与当前大小匹配；无需终态心跳", verifiedAt: verifiedAt)
        } catch { return .init(state: .mismatch, label: "下载文件缺失或已变化", note: "历史校验记录保留；当前文件存在和大小未通过") }
    }
    static func quantization(_ manifest: DownloadManifest, _ snapshot: DownloadSnapshot, download: ModelStateDetail, root: URL, now: Date) -> ModelStateDetail {
        guard download.state == .verified else { return .init(state: .pending, label: "等待下载核验", note: "完成记录与当前文件通过后核对量化") }
        let statusURL = root.appendingPathComponent("quantization-status.json")
        guard let status = try? object(statusURL) else { return .unknown("量化记录待核对", "未取得有效的量化终态记录") }
        if status["status"] as? String == "failed" || (status["cli_exit_code"] as? Int).map({ $0 != 0 }) == true {
            return .init(state: .failed, label: "量化失败", note: "退出码或量化状态未通过；已完成下载仍保留")
        }
        guard status["status"] as? String == "verified_ready" else {
            return .init(state: .pending, label: "量化尚未核验完成", note: "只按真实状态显示，不由下载 100% 推断")
        }
        do {
            let modelRoot = root.appendingPathComponent("models/" + ModelValidationContext.modelKey)
            let resultURL = root.appendingPathComponent("restoration-result.json")
            try require(status["cli_exit_code"] as? Int == 0 && status["outputs_verified"] as? Bool == true && status["registry_verified"] as? Bool == true && status["completion_result_file"] as? String == resultURL.path && status["cwd"] as? String == root.path, "量化终态字段或结果路径不匹配")
            let parameters = status["quantization_parameters"] as? [String: Any] ?? [:]
            try require(parameters["bits"] as? Int == 8 && parameters["group_size"] as? Int == 64 && parameters["quant_modulation"] as? Bool == true, "量化参数与核准 8-bit 配置不匹配")
            try require(!snapshot.quantization_still_required && snapshot.quantization_status == "verified_ready" && snapshot.quantization_cli_exit_code == 0 && snapshot.preparation_phase == "prepared_verified" && snapshot.prepared_model_key == ModelValidationContext.modelKey && snapshot.prepared_model_root == modelRoot.path && snapshot.quantization_status_file == statusURL.path && snapshot.restoration_result_file == resultURL.path, "下载与量化记录之间的绑定不匹配")
            let result = try object(resultURL), preparation = result["preparation"] as? [String: Any] ?? [:], downloads = result["downloads"] as? [String: Any] ?? [:], evidence = result["evidence"] as? [String: Any] ?? [:]
            let registryURL = root.appendingPathComponent("data.mdb")
            try require(result["status"] as? String == "prepared_verified" && preparation["native_exit_code"] as? Int == 0 && preparation["outputs_verified"] as? Bool == true && preparation["current_registry_records_verified"] as? Bool == true && preparation["model_key"] as? String == ModelValidationContext.modelKey && preparation["model_root"] as? String == modelRoot.path && preparation["registry_file"] as? String == registryURL.path && preparation["registry_working_directory"] as? String == root.path && preparation["bits"] as? Int == 8 && preparation["group_size"] as? Int == 64 && preparation["quant_modulation"] as? Bool == true, "量化结果或注册位置不匹配")
            try require(downloads["files_verified"] as? Int == manifest.files.count && downloads["total_files"] as? Int == manifest.files.count && (downloads["bytes_verified"] as? NSNumber)?.int64Value == manifest.total_bytes && downloads["publisher_checksums_verified"] as? Bool == true, "量化结果对应的下载清单不匹配")
            try require(evidence["download_manifest"] as? String == root.appendingPathComponent("download-manifest.json").path && evidence["output_verification"] as? String == root.appendingPathComponent("quantized-output-verification.json").path && evidence["registry_verification"] as? String == root.appendingPathComponent("registry-verification.json").path, "量化核验记录路径不匹配")
            let output = try object(root.appendingPathComponent("quantized-output-verification.json"))
            try require(output["status"] as? String == "verified" && output["model_root"] as? String == modelRoot.path && output["model_key"] as? String == ModelValidationContext.modelKey, "量化输出记录不匹配")
            let components = output["components"] as? [[String: Any]] ?? []
            try require(components.count == 2 && Set(components.compactMap { $0["role"] as? String }) == ["diffusion_models", "text_encoders"], "必要量化组件不完整")
            for component in components {
                let role = component["role"] as! String, directory = modelRoot.appendingPathComponent(role)
                let config = try object(directory.appendingPathComponent("config.json"))
                try require(NSDictionary(dictionary: config).isEqual(to: component["config"] as? [String: Any] ?? [:]), "当前量化配置已变化")
                let parameters = config["quantization"] as? [String: Any] ?? [:]
                try require(parameters["bits"] as? Int == 8 && parameters["group_size"] as? Int == 64 && component["all_passthrough_tensor_bytes_verified"] as? Bool == true && component["index_mapping_and_tensor_bounds_verified"] as? Bool == true, "量化配置或完整性记录不匹配")
                let shards = component["shards"] as? [[String: Any]] ?? [], count = role == "diffusion_models" ? 7 : 6
                try require(shards.count == count, "量化分片数量不匹配")
                let index = try object(directory.appendingPathComponent("model.safetensors.index.json")), mapping = index["weight_map"] as? [String: String] ?? [:]
                var names: Set<String> = []
                for (offset, shard) in shards.enumerated() {
                    let name = String(format: "model-%05d-of-%05d.safetensors", offset + 1, count), url = directory.appendingPathComponent(name)
                    try require(shard["path"] as? String == url.path && ModelStatusReader.isHash(shard["local_sha256"] as? String ?? "", length: 64), "量化分片绑定不匹配")
                    guard let bytes = (shard["size_bytes"] as? NSNumber)?.int64Value, bytes > 0 else { throw CheckFailure(note: "量化分片大小记录缺失") }
                    try ModelStatusReader.requireFile(url, bytes: bytes); names.insert(name)
                }
                try require(!mapping.isEmpty && mapping.count == component["output_tensors"] as? Int && Set(mapping.values) == names, "当前量化索引与分片不匹配")
            }
            let unchanged = output["unchanged_components"] as? [[String: Any]] ?? []
            let required = ["vae/minimax_h3_video_vae_fp16.safetensors", "vae/minimax_h3_audio_vae_fp32.safetensors", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "LICENSE"]
            try require(unchanged.count == required.count && Set(unchanged.compactMap { $0["relative_path"] as? String }) == Set(required), "必要原精度组件不完整")
            for component in unchanged {
                let relative = component["relative_path"] as! String
                guard let original = manifest.files.first(where: { $0.relative_path == "Comfy-Org/MiniMax-H3/" + relative }) else { throw CheckFailure(note: "原精度组件不属于核准清单") }
                try require((component["size_bytes"] as? NSNumber)?.int64Value == original.size && component["same_device_inode_verified"] as? Bool == true, "原精度组件记录不匹配")
                try ModelStatusReader.requireFile(modelRoot.appendingPathComponent(relative), bytes: original.size)
            }
            let lora = output["lora"] as? [String: Any] ?? [:], resultLora = result["lora"] as? [String: Any] ?? [:]
            guard let originalLora = manifest.files.first(where: { $0.relative_path == "larryvrh/MiniMax-H3-Turbo-Lora/minimax_h3_turbo_v4_step600_ema.safetensors" }) else { throw CheckFailure(note: "Turbo LoRA 清单不匹配") }
            let loraURL = root.appendingPathComponent("clean-model-inputs/" + originalLora.relative_path)
            try require(lora["key"] as? String == ModelValidationContext.loraKey && resultLora["key"] as? String == ModelValidationContext.loraKey && lora["path"] as? String == loraURL.path && resultLora["path"] as? String == loraURL.path && lora["same_verified_source_inode"] as? Bool == true, "Turbo LoRA 注册绑定不匹配")
            try ModelStatusReader.requireFile(loraURL, bytes: originalLora.size)
            let registry = try object(root.appendingPathComponent("registry-verification.json"))
            try require(registry["status"] as? String == "verified" && registry["registry"] as? String == registryURL.path && registry["registry_bytes_unchanged"] as? Bool == true && registry["registry_sha256"] as? String == ModelStatusReader.digest(registryURL, limit: 16_777_216), "当前注册文件与核验指纹不匹配")
            let records = registry["records"] as? [[String: Any]] ?? []
            for (key, path, type) in [(ModelValidationContext.modelKey, modelRoot.path, "minimax-h3-fl2va"), (ModelValidationContext.loraKey, loraURL.deletingLastPathComponent().path, "minimax-h3-lora")] {
                let matching = records.filter { $0["key"] as? String == key }
                let record = matching.first?["record"] as? [String: Any] ?? [:]
                try require(matching.count == 1 && record["local_path"] as? String == path && record["model_type"] as? String == type && matching.first?["path_exists"] as? Bool == true, "模型或 LoRA 注册记录不匹配")
                if key == ModelValidationContext.modelKey { try require(record["quantized"] as? Bool == true && record["bits"] as? Int == 8, "模型注册量化配置不匹配") }
            }
            guard let verifiedAt = date(result["completed_at"]), verifiedAt == date(status["updated_at"]), verifiedAt.timeIntervalSince(now) <= 45 else { throw CheckFailure(note: "量化终态验证时间不匹配") }
            return .init(state: .verified, label: "8-bit 量化与注册已核验", note: "退出码 0、13 个分片、原精度组件、LoRA 和当前注册指纹通过；完整权重校验沿用恢复记录", verifiedAt: verifiedAt)
        } catch let failure as CheckFailure { return .init(state: .mismatch, label: "量化完成证据不一致", note: failure.note) }
        catch { return .init(state: .mismatch, label: "量化文件缺失或不可读", note: "必要文件、索引或注册未通过；不将旧终态强制就绪") }
    }
    static func runtime(root: URL, context: ModelValidationContext, quantization: ModelStateDetail) -> (ModelStateDetail, Bool?) {
        guard quantization.state == .verified else { return (.init(state: .pending, label: "等待量化与注册核验", note: "运行时状态与下载进度分别核对"), nil) }
        guard let helper = context.helper, let library = context.library else { return (.unknown("运行时路径待核准", "当前恢复位置没有核准的本地运行时绑定"), nil) }
        do {
            let data = try ModelStatusReader.bounded(root.appendingPathComponent("single-shot-native-app-contract-v2.json"), limit: 1_048_576)
            let contract = try JSONDecoder().decode(H3NativeContract.self, from: data), native = contract.native_runtime
            let template = contract.native_app_process_contract.run_existing_single_shot_wrapper
            try require(contract.version == 2 && contract.integration_kind == "native_local_child_process" && !contract.requires_http_or_webpage_bridge && contract.native_app_process_contract.launcher == "Foundation.Process" && native.working_directory == root.path && native.helper_path == helper.path && native.helper_sha256 == context.helperSHA256 && native.max_generators == 1 && native.memory_cap_mb == 12288 && native.wired_pool_mb == 8192 && contract.do_not_run_previous_claimed_job && contract.observed_candidate.do_not_run_this_job_again, "运行时契约版本、路径或资源边界不匹配")
            try require(template.executable == "/usr/bin/python3" && template.current_directory == root.path && template.arguments.count == 6 && template.arguments[0] == root.appendingPathComponent("run_single_shot.py").path && template.arguments[1] == "--job" && template.arguments[3] == "--work-dir" && template.arguments[4] == root.path && template.arguments[5] == "--run", "单镜启动契约不匹配")
            let audit = try object(root.appendingPathComponent("local-audit.json")), auditRuntime = audit["runtime"] as? [String: Any] ?? [:], registry = try object(root.appendingPathComponent("registry-verification.json"))
            try require(auditRuntime["helper_sha256"] as? String == context.helperSHA256 && auditRuntime["library_sha256"] as? String == context.librarySHA256 && registry["native_library_sha256"] as? String == context.librarySHA256, "运行时核验记录指纹不匹配")
            try require(try ModelStatusReader.digest(helper, limit: 2_097_152) == context.helperSHA256 && ModelStatusReader.digest(library, limit: 67_108_864) == context.librarySHA256, "当前运行时文件指纹已变化")
            try ModelStatusReader.requireFile(root.appendingPathComponent("run_single_shot.py"), limit: 1_048_576)
            try ModelStatusReader.requireFile(root.appendingPathComponent("validate_single_shot.py"), limit: 1_048_576)
            return (.init(state: .verified, label: "运行时与 v2 契约已核对", note: "并发 1 · 内存上限 12 GiB；" + (contract.next_generation_authorized ? "仍需新的单镜绑定与逐镜确认" : "本次真实生成尚未授权")), contract.next_generation_authorized)
        } catch let failure as CheckFailure { return (.init(state: .mismatch, label: "运行时核对未通过", note: failure.note), nil) }
        catch { return (.init(state: .mismatch, label: "运行时文件缺失或不可读", note: "只读核对未通过，未加载模型或启动引擎"), nil) }
    }
}

enum ModelTaskBindingSummary {
    static func detail(jobs: [ShotJob], selectedID: UUID?) -> ModelStateDetail {
        let pending = jobs.filter { $0.engine == .h3 && $0.status.isPending }
        guard let job = pending.first(where: { $0.id == selectedID }) ?? pending.first else {
            return .init(state: .pending, label: "未选择待生成 H3 镜头", note: "新增或导入镜头后，绑定新的核准单镜")
        }
        let shot = String(format: "S%02d", job.shot) + " · " + job.title
        guard let binding = job.h3Binding else {
            return .init(state: .pending, label: "镜头尚未绑定 · 不能生成", note: shot + "；模型准备完成不会自动绑定镜头")
        }
        return .init(state: .pending, label: binding.executionAuthorized ? "单镜已绑定 · 待逐镜确认" : "单镜已绑定 · 等待生成授权", note: shot + "；执行前仍会重新校对冻结任务与契约")
    }
}
