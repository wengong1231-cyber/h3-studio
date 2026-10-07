import Foundation

struct H3ABTaskBinding: Codable, Equatable {
    var appJobID: UUID
    var appWorkspace: String
    var configuration: H3ABConfiguration
    var configurationPath: String
    var configurationSHA256: String
    var descriptorSnapshotPath: String
    var pipelineTemplateSHA256: String
    static let templateSHA256 = "1b2e5247fb12d8b5007687895d9d457d80d67b5859b5298ce88e4b2016c6b01e"

    static func template(_ executable: URL) throws -> Data {
        let path = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/H3S41ABPipelineTemplate.json")
        let data = try H3Files.read(path,limit:262_144)
        guard H3ABConfigurationReader.digest(data) == templateSHA256 else { throw StudioError.invalid("S41 管线模板与已核源码不同。") }
        return data
    }
    static func pipeline(template: Data, id: String, first: String, last: String, prompt: String, seed: Int, directory: String) throws -> Data {
        guard H3ABConfigurationReader.digest(template) == templateSHA256,
              let inert = try JSONSerialization.jsonObject(with:template) as? [String:Any],
              var graph = inert["pipeline"] as? [String:Any], var stages = graph["stages"] as? [[String:Any]] else { throw StudioError.invalid("S41 A/B 模板不可绑定。") }
        graph["id"] = id
        for index in stages.indices {
            guard let name = stages[index]["id"] as? String,var config = stages[index]["config"] as? [String:Any] else { throw StudioError.invalid("S41 管线阶段缺少配置。") }
            switch name {
            case "load-A": config["url"] = [first]
            case "load-B": config["url"] = [last]
            case "text-prompt": config["text"] = prompt
            case "generate-video": config["seed"] = seed
            case "save-video": config["output_url"] = directory + "/S41-AB-native-73frames.mp4"
            case "save-detail-frames": config["path"] = directory + "/record/lossless-frames/frame-%04d.png"
            case "save-detail-source": config["path"] = directory + "/record/source-A-resized.png"
            case "save-detail-source-B": config["path"] = directory + "/record/source-B-resized.png"
            default: break
            }
            stages[index]["config"] = config
        }
        graph["stages"] = stages
        return try JSONSerialization.data(withJSONObject:graph,options:[.sortedKeys,.prettyPrinted])
    }
    static func materialize(jobID: UUID, workspace: URL, configuration: H3ABConfiguration, executable: URL, runtime: H3Runtime) throws -> (H3Binding,H3SingleJob) {
        guard configuration.blockers.isEmpty,configuration.launchAuthorized,let snapshot = configuration.snapshotPath,
              let a = configuration.first.originalPath,let an = configuration.first.normalizedPath,
              let b = configuration.last.originalPath,let bn = configuration.last.normalizedPath,let prompt = configuration.prompt,
              configuration.automaticInputsValidated else { throw StudioError.invalid("S41 A/B 缺少有效素材、自动输入检查或提示词。") }
        _ = try H3Files.inside(snapshot,workspace.path + "/h3-config")
        let descriptorData = try H3Files.read(URL(fileURLWithPath:snapshot),limit:1_048_576)
        guard H3ABConfigurationReader.digest(descriptorData) == configuration.sourceSHA256 else { throw StudioError.invalid("保存的 S41 配置快照发生变化。") }
        let current = try H3ABConfigurationReader.parse(descriptorData,sourcePath:configuration.sourcePath,workDirectory:runtime.workDirectory,mock:runtime.mode == .mock).configuration
        var expected = configuration;expected.snapshotPath = nil;expected.revision = 1
        guard current == expected else { throw StudioError.invalid("S41 素材与保存的配置不再一致，未创建执行任务。") }
        let identity = "app-s41-ab-" + jobID.uuidString.lowercased()
        let directory = try H3Files.inside(runtime.workDirectory + "/candidates/" + identity,runtime.workDirectory + "/candidates")
        let fm = FileManager.default
        guard !fm.fileExists(atPath:directory.path) else { throw StudioError.invalid("此 App S41 身份已经材料化，不能覆盖或重新领取。") }
        let record = directory.appendingPathComponent("record",isDirectory:true)
        try fm.createDirectory(at:record.appendingPathComponent("lossless-frames"),withIntermediateDirectories:true)
        let inputs = record.appendingPathComponent("inputs",isDirectory:true);try fm.createDirectory(at:inputs,withIntermediateDirectories:true)
        var frozen: [String:String] = [:]
        var copies: [String:URL] = [:]
        for (name,path,hash) in [("A-original",a,configuration.first.originalSHA256!), ("A-normalized",an,configuration.first.normalizedSHA256!), ("B-original",b,configuration.last.originalSHA256!), ("B-normalized",bn,configuration.last.normalizedSHA256!)] {
            let source = try H3ABConfigurationReader.imagePath(path,workDirectory:runtime.workDirectory,mock:runtime.mode == .mock)
            guard try WorkspaceDigest.sha256(source) == hash else { throw StudioError.invalid("材料化时 S41 \(name) 输入变化。") }
            let target = inputs.appendingPathComponent(name + ".png")
            try fm.copyItem(at:source,to:target)
            guard try WorkspaceDigest.sha256(target) == hash else { throw StudioError.invalid("S41 输入复制校验失败。") }
            frozen[source.path] = hash;frozen[target.path] = hash;copies[name] = target
        }
        let descriptorSnapshot = record.appendingPathComponent("input-contract.json")
        try descriptorData.write(to:descriptorSnapshot,options:.withoutOverwriting);frozen[descriptorSnapshot.path] = configuration.sourceSHA256
        let configurationPath = record.appendingPathComponent("app-configuration.json")
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let configurationData = try encoder.encode(configuration);try configurationData.write(to:configurationPath,options:.withoutOverwriting)
        let configurationHash = H3ABConfigurationReader.digest(configurationData);frozen[configurationPath.path] = configurationHash
        let templateData = try template(executable)
        let pipelineURL = directory.appendingPathComponent("S41-AB.vpipeline")
        let pipelineData = try pipeline(template:templateData,id:identity,first:copies["A-normalized"]!.path,last:copies["B-normalized"]!.path,prompt:prompt,seed:configuration.seed,directory:directory.path)
        try pipelineData.write(to:pipelineURL,options:.withoutOverwriting);frozen[pipelineURL.path] = H3ABConfigurationReader.digest(pipelineData)
        let metadata = Self(appJobID:jobID,appWorkspace:workspace.path,configuration:configuration,configurationPath:configurationPath.path,configurationSHA256:configurationHash,descriptorSnapshotPath:descriptorSnapshot.path,pipelineTemplateSHA256:templateSHA256)
        let job = H3SingleJob(version:2,job_id:identity,shot_number:41,segment_id:"s41-p01",authorization:.init(user_authorized:true,max_generators:1,no_automatic_retry:true,no_auto_queue:true),work_dir:runtime.workDirectory,output_dir:directory.path,pipeline_path:pipelineURL.path,clip_path:directory.path + "/S41-AB-native-73frames.mp4",helper_path:configuration.helperPath,helper_sha256:configuration.helperSHA256,library_path:configuration.libraryPath,library_sha256:configuration.librarySHA256,source_image:copies["A-normalized"]!.path,source_image_sha256:configuration.first.normalizedSHA256!,model_ref:"local/MiniMax-H3-FL2VA-8bit",lora_ref:"larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",profile:.s41AB,seed:configuration.seed,prompt_sha256:configuration.promptSHA256!,frozen:frozen,minimum_free_bytes:runtime.mode == .mock ? 0 : 20 * 1_073_741_824,max_wall_seconds:3600,selected_for_production:false,mock_scenario:runtime.mode == .mock ? (configuration.mockScenario ?? "normal") : nil,app_ab_task:metadata,last_source_image:copies["B-normalized"]!.path,last_source_image_sha256:configuration.last.normalizedSHA256)
        let jobURL = directory.appendingPathComponent("job.json");try encoder.encode(job).write(to:jobURL,options:.withoutOverwriting)
        return try load(jobURL,runtime:runtime)
    }
    /// Old completed A/B jobs predate automaticCheck. Recomputed checks must
    /// still pass; only their absent historical metadata may differ. Dispatch
    /// never opts into this read-only compatibility path.
    static func configurationsMatch(_ parsed: H3ABConfiguration,_ saved: H3ABConfiguration,allowHistoricalInputChecks: Bool) -> Bool {
        if parsed == saved { return true }
        guard allowHistoricalInputChecks,parsed.automaticInputsValidated,
              saved.first.automaticCheck == nil,saved.last.automaticCheck == nil,
              saved.first.visuallyReviewed,saved.last.visuallyReviewed else { return false }
        var historical = parsed
        historical.first.automaticCheck = nil;historical.last.automaticCheck = nil
        return historical == saved
    }
    static func load(_ url: URL, runtime: H3Runtime, requireFresh: Bool = true,allowHistoricalInputChecks: Bool = false) throws -> (H3Binding,H3SingleJob) {
        guard !allowHistoricalInputChecks || !requireFresh else { throw StudioError.invalid("历史图片检查兼容仅用于读取，不能用于领取新执行。") }
        let fm = FileManager.default
        let job = try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(url))
        guard let ab = job.app_ab_task,job.version == 2,job.shot_number == 41,job.segment_id == "s41-p01",job.profile == .s41AB,
              job.job_id == "app-s41-ab-" + ab.appJobID.uuidString.lowercased(),job.work_dir == runtime.workDirectory,
              ab.configuration.workDirectory == runtime.workDirectory,ab.configuration.blockers.isEmpty,ab.configuration.launchAuthorized,
              job.authorization.user_authorized,job.authorization.max_generators == 1,job.authorization.no_automatic_retry,job.authorization.no_auto_queue,
              job.model_ref == "local/MiniMax-H3-FL2VA-8bit",job.lora_ref == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",job.seed == ab.configuration.seed,
              job.helper_path == ab.configuration.helperPath,job.helper_sha256 == ab.configuration.helperSHA256,
              job.library_path == ab.configuration.libraryPath,job.library_sha256 == ab.configuration.librarySHA256,
              job.prompt_sha256 == ab.configuration.promptSHA256,job.source_image_sha256 == ab.configuration.first.normalizedSHA256,
              job.last_source_image_sha256 == ab.configuration.last.normalizedSHA256,job.last_source_image != nil,
              job.max_wall_seconds == 3600,!job.selected_for_production,ab.pipelineTemplateSHA256 == templateSHA256,
              runtime.mode == .mock || (job.mock_scenario == nil && job.minimum_free_bytes >= 20 * 1_073_741_824),job.frozen.count <= 32 else { throw StudioError.invalid("App S41 身份、73 帧配置或输入绑定不匹配。") }
        _ = try H3Files.safe(ab.appWorkspace)
        _ = try H3Files.inside(job.output_dir,runtime.workDirectory + "/candidates")
        guard job.output_dir == runtime.workDirectory + "/candidates/" + job.job_id,url.path == job.output_dir + "/job.json" else { throw StudioError.invalid("App S41 输出不是独立新候选目录。") }
        let configURL = try H3Files.inside(ab.configurationPath,job.output_dir),descriptor = try H3Files.inside(ab.descriptorSnapshotPath,job.output_dir)
        let configData = try H3Files.read(configURL,limit:1_048_576)
        guard H3ABConfigurationReader.digest(configData) == ab.configurationSHA256,
              try JSONDecoder().decode(H3ABConfiguration.self,from:configData) == ab.configuration,
              try WorkspaceDigest.sha256(descriptor) == ab.configuration.sourceSHA256,
              job.frozen[configURL.path] == ab.configurationSHA256,job.frozen[descriptor.path] == ab.configuration.sourceSHA256 else { throw StudioError.invalid("App S41 配置快照或指纹变化。") }
        var parsed = try H3ABConfigurationReader.parse(H3Files.read(descriptor),sourcePath:ab.configuration.sourcePath,workDirectory:runtime.workDirectory,mock:runtime.mode == .mock).configuration
        parsed.revision = ab.configuration.revision;parsed.snapshotPath = ab.configuration.snapshotPath
        guard configurationsMatch(parsed,ab.configuration,allowHistoricalInputChecks:allowHistoricalInputChecks) else { throw StudioError.invalid("App S41 原始素材、配置与记录不一致。") }
        for (path,hash) in job.frozen {
            let file: URL
            if path.hasPrefix(job.output_dir + "/") { file = try H3Files.inside(path,job.output_dir) }
            else { file = try H3ABConfigurationReader.imagePath(path,workDirectory:runtime.workDirectory,mock:runtime.mode == .mock) }
            guard ModelStatusReader.isHash(hash,length:64),try WorkspaceDigest.sha256(file) == hash else { throw StudioError.invalid("App S41 冻结文件变化：" + file.lastPathComponent) }
        }
        let pipelineURL = try H3Files.inside(job.pipeline_path,job.output_dir)
        let expectedPipeline = try pipeline(template:H3Files.readTemplateFallback(),id:job.job_id,first:job.source_image,last:job.last_source_image!,prompt:ab.configuration.prompt!,seed:job.seed,directory:job.output_dir)
        guard try H3Files.read(pipelineURL) == expectedPipeline,job.frozen[pipelineURL.path] != nil,
              job.clip_path == job.output_dir + "/S41-AB-native-73frames.mp4",
              job.source_image == job.output_dir + "/record/inputs/A-normalized.png",job.last_source_image == job.output_dir + "/record/inputs/B-normalized.png" else { throw StudioError.invalid("S41 管线与 A/B、提示词、端口或输出配置不同。") }
        if runtime.mode == .real {
            guard runtime == .real,job.helper_sha256 == H3ABConfigurationReader.helperSHA256,job.library_sha256 == H3ABConfigurationReader.librarySHA256,
                  try WorkspaceDigest.sha256(H3Files.safe(job.helper_path)) == job.helper_sha256,
                  try WorkspaceDigest.sha256(H3Files.safe(job.library_path)) == job.library_sha256 else { throw StudioError.invalid("S41 已核原生运行文件发生变化。") }
        }
        if requireFresh {
            for suffix in ["/attempt-once.json","/status.json","/technical-validation.json","/record/native-run.log","/S41-AB-native-73frames.mp4"] {
                guard !fm.fileExists(atPath:job.output_dir + suffix) else { throw StudioError.invalid("App S41 已领取或有输出，不能重跑。") }
            }
            let frames = try fm.contentsOfDirectory(atPath:job.output_dir + "/record/lossless-frames")
            guard frames.isEmpty else { throw StudioError.invalid("S41 无损帧目录已占用。") }
        }
        return (H3Binding(runtime:runtime,jobPath:url.path,jobSHA256:try WorkspaceDigest.sha256(url),contractSHA256:ab.configurationSHA256,runnerSHA256:job.helper_sha256,validatorSHA256:job.library_sha256,nativeJobID:job.job_id,outputDirectory:job.output_dir,clipPath:job.clip_path,profile:job.profile,minimumFreeBytes:job.minimum_free_bytes,executionAuthorized:true,appABTask:ab),job)
    }
}

extension H3Files {
    static func readTemplateFallback() throws -> Data {
        try H3ABTaskBinding.template(URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL)
    }
}
