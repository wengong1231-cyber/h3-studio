import Foundation

enum ReadinessFixtures {
    static func write(_ root: URL, age: TimeInterval = 86_400) throws -> ModelValidationContext {
        let fm = FileManager.default
        func bytes(_ path: String, _ text: String = "fixture-only") throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        func json(_ name: String, _ value: [String: Any]) throws {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        }
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age))
        let base = "Comfy-Org/MiniMax-H3/"
        let unchanged = ["vae/minimax_h3_video_vae_fp16.safetensors", "vae/minimax_h3_audio_vae_fp32.safetensors", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "LICENSE"]
        let loraPath = "larryvrh/MiniMax-H3-Turbo-Lora/minimax_h3_turbo_v4_step600_ema.safetensors"
        let relative = [base + "diffusion_models/minimax_h3_fl2va_bf16.safetensors", base + "text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors"] + unchanged.map { base + $0 } + [loraPath]
        var identities: [[String: Any]] = [], states: [[String: Any]] = [], pins: [String: String] = [:]
        for name in relative {
            let file = try bytes("models/" + name), hash = try WorkspaceDigest.sha256(file)
            let revision = String(repeating: "a", count: 40)
            let identity: [String: Any] = ["relative_path":name, "remote_path":name, "repo":"fixture-only", "revision":revision, "size":12, "sha256":hash]
            identities.append(identity); pins[name] = "fixture-only:" + revision + ":" + hash
            var state = identity; state["state"] = "verified"; state["downloaded_bytes"] = 12; state["publisher_checksum_verified"] = true; states.append(state)
        }
        let modelRoot = root.appendingPathComponent("models/" + ModelValidationContext.modelKey)
        try json("download-manifest.json", ["version":1, "model_dir":root.appendingPathComponent("models").path, "original_quantized_model_key":ModelValidationContext.modelKey, "lora_key":ModelValidationContext.loraKey, "total_bytes":96, "files":identities])
        try json("download-status.json", ["version":1, "status":"verified", "model_dir":root.appendingPathComponent("models").path, "updated_at":date, "downloaded_bytes":96, "expected_bytes":96, "verified_files":8, "total_files":8, "quantization_still_required":false, "generation_started":false, "files":states, "quantization_status":"verified_ready", "quantization_cli_exit_code":0, "quantization_status_file":root.appendingPathComponent("quantization-status.json").path, "prepared_model_key":ModelValidationContext.modelKey, "prepared_model_root":modelRoot.path, "preparation_phase":"prepared_verified", "restoration_result_file":root.appendingPathComponent("restoration-result.json").path])
        try json("quantization-status.json", ["status":"verified_ready", "updated_at":date, "cli_exit_code":0, "cwd":root.path, "outputs_verified":true, "registry_verified":true, "quantization_parameters":["bits":8,"group_size":64,"quant_modulation":true], "completion_result_file":root.appendingPathComponent("restoration-result.json").path])
        var components: [[String: Any]] = []
        for (role,count) in [("diffusion_models",7),("text_encoders",6)] {
            let config: [String: Any] = ["quantization":["bits":8,"group_size":64], "fixture_only":true]
            try json("models/" + ModelValidationContext.modelKey + "/" + role + "/config.json", config)
            var shards: [[String: Any]] = [], mapping: [String: String] = [:]
            for index in 1...count {
                let name = String(format:"model-%05d-of-%05d.safetensors",index,count)
                let shard = try bytes("models/" + ModelValidationContext.modelKey + "/" + role + "/" + name)
                shards.append(["path":shard.path,"size_bytes":12,"local_sha256":try WorkspaceDigest.sha256(shard)])
                mapping["fixture-tensor-\(index)"] = name
            }
            try json("models/" + ModelValidationContext.modelKey + "/" + role + "/model.safetensors.index.json", ["weight_map":mapping])
            components.append(["role":role,"config":config,"shards":shards,"output_tensors":count,"all_passthrough_tensor_bytes_verified":true,"index_mapping_and_tensor_bounds_verified":true])
        }
        var passthrough: [[String: Any]] = []
        for name in unchanged { _ = try bytes("models/" + ModelValidationContext.modelKey + "/" + name); passthrough.append(["relative_path":name,"size_bytes":12,"same_device_inode_verified":true]) }
        let loraFile = try bytes("clean-model-inputs/" + loraPath)
        let lora: [String: Any] = ["key":ModelValidationContext.loraKey,"path":loraFile.path,"same_verified_source_inode":true]
        try json("quantized-output-verification.json", ["status":"verified","model_root":modelRoot.path,"model_key":ModelValidationContext.modelKey,"components":components,"unchanged_components":passthrough,"lora":lora])
        let registry = try bytes("data.mdb","fixture registry only")
        let helper = try bytes("runtime/vpipe","fixture helper only"), library = try bytes("runtime/libvpipe.0.dylib","fixture library only")
        let helperHash = try WorkspaceDigest.sha256(helper), libraryHash = try WorkspaceDigest.sha256(library)
        let records: [[String: Any]] = [
            ["key":ModelValidationContext.modelKey,"path_exists":true,"record":["local_path":modelRoot.path,"model_type":"minimax-h3-fl2va","quantized":true,"bits":8]],
            ["key":ModelValidationContext.loraKey,"path_exists":true,"record":["local_path":loraFile.deletingLastPathComponent().path,"model_type":"minimax-h3-lora"]]]
        try json("registry-verification.json", ["status":"verified","registry":registry.path,"registry_sha256":try WorkspaceDigest.sha256(registry),"registry_bytes_unchanged":true,"native_library_sha256":libraryHash,"records":records])
        try json("restoration-result.json", ["status":"prepared_verified","completed_at":date,"downloads":["files_verified":8,"total_files":8,"bytes_verified":96,"publisher_checksums_verified":true], "preparation":["model_key":ModelValidationContext.modelKey,"model_root":modelRoot.path,"registry_file":registry.path,"registry_working_directory":root.path,"bits":8,"group_size":64,"quant_modulation":true,"native_exit_code":0,"outputs_verified":true,"current_registry_records_verified":true], "lora":lora, "evidence":["download_manifest":root.appendingPathComponent("download-manifest.json").path,"output_verification":root.appendingPathComponent("quantized-output-verification.json").path,"registry_verification":root.appendingPathComponent("registry-verification.json").path]])
        try json("local-audit.json", ["runtime":["helper_sha256":helperHash,"library_sha256":libraryHash],"conversion_plan":["history_derived_disk_estimate":["additional_quantized_unique_allocated_bytes":63932743680 as Int64]]])
        _ = try bytes("run_single_shot.py"); _ = try bytes("validate_single_shot.py")
        try json("single-shot-native-app-contract-v2.json", ["version":2,"integration_kind":"native_local_child_process","requires_http_or_webpage_bridge":false,"native_runtime":["helper_path":helper.path,"helper_sha256":helperHash,"working_directory":root.path,"memory_cap_mb":12288,"wired_pool_mb":8192,"max_generators":1],"native_app_process_contract":["launcher":"Foundation.Process","run_existing_single_shot_wrapper":["executable":"/usr/bin/python3","arguments":[root.appendingPathComponent("run_single_shot.py").path,"--job","<fresh job>","--work-dir",root.path,"--run"],"current_directory":root.path]],"observed_candidate":["job":root.appendingPathComponent("candidates/old/job.json").path,"do_not_run_this_job_again":true],"next_generation_authorized":false,"do_not_run_previous_claimed_job":true])
        return ModelValidationContext(helper:helper,library:library,helperSHA256:helperHash,librarySHA256:libraryHash,pinnedSourceSignatures:pins)
    }
}

@MainActor enum ReadinessSelfTests {
    static func statusProfile(report: URL) async -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached(priority: .utility) { ModelStatusReader.read(AppIdentity.modelStatusRoot) }.value
        do {
            let value = try result.get()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let states = try JSONSerialization.jsonObject(with: encoder.encode(value.verification))
            let summary: [String: Any] = ["version":AppIdentity.version,"readSucceeded":true,"elapsedMilliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"sourceUpdatedAt":value.snapshot.updated_at,"sourceHeartbeatStale":value.snapshot.stale(),"downloadedBytes":value.snapshot.downloaded_bytes,"expectedBytes":value.snapshot.expected_bytes,"verifiedFiles":value.snapshot.verified_files,"totalFiles":value.snapshot.total_files,"quantizedAdditionalBytes":value.quantizedAdditionalBytes as Any,"verification":states,"nativeGUIStarted":false,"gpuTasksStarted":0,"modelWeightsHashed":false,"mode":"read-only metadata, current file sizes, registry and runtime hashes"]
            try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:report)
            FileHandle.standardOutput.write(Data("只读核对完成：\(value.verification.download.label)；\(value.verification.quantization.label)；\(value.verification.runtime.label)\n".utf8))
            return 0
        } catch { FileHandle.standardError.write(Data("只读状态核对未完成。\n".utf8)); return 1 }
    }
    static func run(root: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail)); FileHandle.standardOutput.write(Data("\(passed ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !passed { throw StudioError.invalid(name) }
        }
        func mutate(_ url: URL, _ change: (inout [String:Any]) -> Void) throws {
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf:url)) as! [String:Any]; change(&value)
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url)
        }
        func value(_ result: ModelStatusReadResult) throws -> ModelStatusReadValue { try result.get() }
        func prepared(_ name: String) throws -> (URL, ModelValidationContext) { let folder=root.appendingPathComponent(name); return (folder,try ReadinessFixtures.write(folder)) }
        do {
            guard !FileManager.default.fileExists(atPath:root.path) else { throw StudioError.invalid("Readiness test root must be new") }
            let (terminal,context) = try prepared("old-terminal")
            let result = try value(ModelStatusReader.read(terminal,context:context))
            try check("旧的已校验终态保持完成", result.verification.download.state == .verified && !result.snapshot.stale() && result.snapshot.date!.timeIntervalSinceNow < -86_000, "一天前的终态不要求45秒心跳；保留原始验证时间")
            try check("量化必须核对当前文件与注册", result.verification.quantization.state == .verified && result.verification.quantization.verifiedAt == result.snapshot.date, "真实生产验证器检查13分片、索引、原精度组件、LoRA、注册指纹")
            try check("运行时与生成授权分离", result.verification.runtime.state == .verified && result.verification.nextGenerationAuthorized == false, "CPU fixture 的冻结运行时指纹通过，本次生成仍未授权")
            try check("已完成转换不再扣除历史空间", result.quantizedAdditionalBytes == 0, "转换通过后额外待转换空间为0，磁盘余量来自当前卷")
            let monitor = ModelReadinessMonitor(root:terminal,service:ModelStatusReadService { ModelStatusReader.read($0,context:context) })
            monitor.start(); try await StudioSelfTests.wait("terminal UI publication") { monitor.phase == .ready }
            try check("旧终态在监控器保持确认", monitor.hasConfirmedCurrentSnapshot && monitor.currentQuantizationVerified && monitor.currentRuntimeVerified && monitor.reportLabel == "模型下载与量化已核验", "生产monitor发布四状态，未改来源JSON时间")
            let pelican = ShotJob(shot:15,segment:"s15-p01",title:"鹈鹕 · 待核准",prompt:"fixture",requestedDuration:124.0/24,engine:.h3,status:.blocked)
            try check("未绑定镜头独立显示不能生成", ModelTaskBindingSummary.detail(jobs:[pelican],selectedID:pelican.id).label.contains("不能生成") && pelican.h3Binding == nil, "模型准备通过不会绑定或自动排队鹈鹕镜头")
            monitor.stop()
            let (ongoing,ongoingContext) = try prepared("ongoing-stale")
            try mutate(ongoing.appendingPathComponent("download-status.json")) { $0["status"]="running" }
            let stale = try value(ModelStatusReader.read(ongoing,context:ongoingContext))
            try check("进行中的旧心跳仍标为陈旧", stale.snapshot.fraction == 1 && stale.snapshot.stale() && stale.verification.download.state == .stale && stale.verification.quantization.state != .verified, "100%字节但无终态，45秒规则继续生效")
            try mutate(ongoing.appendingPathComponent("download-status.json")) { $0["updated_at"]=ISO8601DateFormatter().string(from:Date()) }
            let fresh = try value(ModelStatusReader.read(ongoing,context:ongoingContext))
            try check("新下载心跳只确认进行中", fresh.verification.download.state == .running && !fresh.snapshot.stale() && fresh.verification.quantization.state == .pending, "不把正在运行的100%下载当作量化完成")
            let (rawMissing,rawContext) = try prepared("raw-missing")
            try FileManager.default.removeItem(at:rawMissing.appendingPathComponent("models/Comfy-Org/MiniMax-H3/LICENSE"))
            let raw = try value(ModelStatusReader.read(rawMissing,context:rawContext))
            try check("已完成下载缺文件拒绝就绪", raw.verification.download.state == .mismatch && raw.verification.quantization.state == .pending, "历史8/8和100%仍展示，当前文件缺失不通过")
            let (shardMissing,shardContext) = try prepared("shard-missing")
            try FileManager.default.removeItem(at:shardMissing.appendingPathComponent("models/" + ModelValidationContext.modelKey + "/diffusion_models/model-00001-of-00007.safetensors"))
            let shard = try value(ModelStatusReader.read(shardMissing,context:shardContext))
            try check("量化分片缺失不影响下载完成", shard.verification.download.state == .verified && shard.verification.quantization.state == .mismatch && shard.quantizedAdditionalBytes != 0, "四层独立状态；量化未通过时不清零历史估计")
            let (registryChanged,registryContext) = try prepared("registry-changed")
            try Data("changed registry".utf8).write(to:registryChanged.appendingPathComponent("data.mdb"))
            let registry = try value(ModelStatusReader.read(registryChanged,context:registryContext))
            try check("当前注册指纹变化拒绝旧证据", registry.verification.quantization.state == .mismatch && registry.verification.runtime.state == .pending, "不依据历史registry_verified=true强制ready")
            let (wrongKey,keyContext) = try prepared("registry-wrong-key")
            try mutate(wrongKey.appendingPathComponent("registry-verification.json")) { d in var records=d["records"] as! [[String:Any]]; records[0]["key"]="local/wrong-model"; d["records"]=records }
            try check("模型注册键不匹配被拒绝", try value(ModelStatusReader.read(wrongKey,context:keyContext)).verification.quantization.state == .mismatch, "文件存在也不能代替模型和LoRA注册键绑定")
            let (failed,failedContext) = try prepared("quantization-failed")
            try mutate(failed.appendingPathComponent("quantization-status.json")) { $0["status"]="failed"; $0["cli_exit_code"]=1 }
            let failure = try value(ModelStatusReader.read(failed,context:failedContext))
            try check("量化失败单独显示", failure.verification.download.state == .verified && failure.verification.quantization.state == .failed && failure.verification.runtime.state == .pending, "成功下载保留，失败量化不冒充运行时就绪")
            let (version,versionContext) = try prepared("version-changed")
            try mutate(version.appendingPathComponent("download-manifest.json")) { $0["version"]=2 }
            if case .failure(.invalidManifest) = ModelStatusReader.read(version,context:versionContext) { try check("未知清单版本拒绝",true,"新版结构需核准，不能套用旧终态") } else { try check("未知清单版本拒绝",false,"expected invalidManifest") }
            let (revision,revisionContext) = try prepared("source-revision-changed")
            for name in ["download-manifest.json","download-status.json"] {
                try mutate(revision.appendingPathComponent(name)) { d in var files=d["files"] as! [[String:Any]]; files[0]["revision"]=String(repeating:"b",count:40); d["files"]=files }
            }
            if case .failure(.invalidManifest) = ModelStatusReader.read(revision,context:revisionContext) { try check("清单与状态同时换版本也拒绝",true,"已核准来源指纹固定，不沿用旧量化完成记录") } else { try check("清单与状态同时换版本也拒绝",false,"expected pinned revision rejection") }
            let (checksum,checksumContext) = try prepared("checksum-not-verified")
            try mutate(checksum.appendingPathComponent("download-status.json")) { d in var files=d["files"] as! [[String:Any]]; files[0]["publisher_checksum_verified"]=false; d["files"]=files }
            try check("字节100%缺校验标记不完成", try value(ModelStatusReader.read(checksum,context:checksumContext)).verification.download.state == .mismatch, "逐文件来源校验标记为必要条件")
            let (runtimeChanged,runtimeContext) = try prepared("runtime-changed")
            try Data("changed runtime".utf8).write(to:runtimeContext.helper!)
            let runtime = try value(ModelStatusReader.read(runtimeChanged,context:runtimeContext))
            try check("运行时变化不撤销模型完成", runtime.verification.quantization.state == .verified && runtime.verification.runtime.state == .mismatch, "当前helper指纹失败独立呈现，不启引擎")
            let (indexChanged,indexContext) = try prepared("index-changed")
            try mutate(indexChanged.appendingPathComponent("models/" + ModelValidationContext.modelKey + "/diffusion_models/model.safetensors.index.json")) { $0["weight_map"]=["tensor":"../outside.safetensors"] }
            try check("索引分片绑定变化被拒绝", try value(ModelStatusReader.read(indexChanged,context:indexContext)).verification.quantization.state == .mismatch, "不遍历索引中的任意路径，只接受已核准分片名")
            let (symlink,symlinkContext) = try prepared("symlink-shard")
            let replaced=symlink.appendingPathComponent("models/" + ModelValidationContext.modelKey + "/diffusion_models/model-00001-of-00007.safetensors")
            try FileManager.default.removeItem(at:replaced); try FileManager.default.createSymbolicLink(at:replaced,withDestinationURL:symlink.appendingPathComponent("models/Comfy-Org/MiniMax-H3/LICENSE"))
            try check("量化必要文件符号链接被拒绝", try value(ModelStatusReader.read(symlink,context:symlinkContext)).verification.quantization.state == .mismatch, "同大小内容也不绕过普通文件规则")
            let unchangedDate = try JSONSerialization.jsonObject(with:Data(contentsOf:terminal.appendingPathComponent("download-status.json"))) as! [String:Any]
            try check("验证不会改来源时间戳", unchangedDate["updated_at"] as? String == ISO8601DateFormatter().string(from:result.snapshot.date!), "只读验证保留终态原始时间，不刷mtime制造鲜度")
            let report:[String:Any] = ["version":AppIdentity.version,"passed":checks.count,"checks":try JSONSerialization.jsonObject(with:JSONEncoder().encode(checks)),"nativeGUIStarted":false,"gpuTasksStarted":0,"originalModelFilesRead":false,"mockWeightsOnly":true]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("readiness-test-report.json"))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Readiness regression failed: \(error.localizedDescription)\n".utf8))
            if let data=try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("readiness-test-report.json")) }
            return 1
        }
    }
}
