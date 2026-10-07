import Foundation
import Security

// A separately authorized diagnostic runtime. It never replaces the helper in
// an existing task binding or enables a model download.
struct H3ReferenceEngineManifest: Codable, Equatable {
    var schema = "jingsheng-isolated-reference-engine-v1"
    var appJobID: UUID
    var version: String
    var bundlePath: String
    var packagePath: String
    var packageSHA256: String
    var helperSHA256: String
    var librarySHA256: String
    var authorizationQuote: String
    var maximumTrials: Int

    func validateScope(_ jobID: UUID) throws {
        guard schema == "jingsheng-isolated-reference-engine-v1",appJobID == jobID,
              version == "0.1.80",maximumTrials == 2,
              authorizationQuote == "允许隔离接入并做小批对照",
              packageSHA256 == H3ReferenceEngine.packageSHA,
              helperSHA256 == H3ReferenceEngine.helperSHA,librarySHA256 == H3ReferenceEngine.librarySHA else {
            throw StudioError.invalid("隔离引擎版本、任务、用户授权或最多两次试验范围不匹配。")
        }
    }
}

struct H3ReferenceModelStamp: Codable, Equatable {
    var path: String
    var size: UInt64
    // Metadata/header identity only, not a claim that full model weights have
    // been rehashed. Existing model registration is checked separately.
    var metadataSHA256: String
}

struct H3ReferenceEngineBinding: Codable, Equatable {
    var manifest: H3ReferenceEngineManifest
    var receiptPath: String
    var receiptSHA256: String
    var modelStamps: [H3ReferenceModelStamp]
    var registeredAt: Date
    var helperPath: String { manifest.bundlePath + "/Contents/Helpers/vpipe" }
    var libraryPath: String { manifest.bundlePath + "/Contents/Frameworks/libvpipe.0.dylib" }

    func validate(jobID: UUID,workspace: String,workDirectory: String) throws {
        try manifest.validateScope(jobID)
        let url = try H3Files.inside(receiptPath,workspace + "/h3-reference-engines/" + jobID.uuidString)
        let bytes = try H3Files.read(url)
        guard H3ABConfigurationReader.digest(bytes) == receiptSHA256,
              let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let declared = object["manifest"],let stamps = object["modelStamps"],
              try JSONDecoder().decode(H3ReferenceEngineManifest.self,from:JSONSerialization.data(withJSONObject:declared)) == manifest,
              try JSONDecoder().decode([H3ReferenceModelStamp].self,from:JSONSerialization.data(withJSONObject:stamps)) == modelStamps else {
            throw StudioError.invalid("隔离引擎登记回执已变化。")
        }
        try H3ReferenceEngine.verifyRuntime(manifest)
        guard try H3ReferenceEngine.modelStamps(workDirectory:workDirectory) == modelStamps else {
            throw StudioError.invalid("参考模式的本机视觉权重或元数据已变化；未启动，也不会下载模型。")
        }
    }
}

enum H3ReferenceEngine {
    static let packageSHA = "527afe4651a2a35b880de7223658c3b0648349479aae9a1b5bdc90d6170b3a28"
    static let helperSHA = "4d3852bffa7e8e67e503d51a3237e48577650ad12c2e88567c9d1acb9efc0841"
    static let librarySHA = "cb131970a6aeb5d31196ed8137b093c805126375442111ac48705b25c5374c39"
    static let vendorRequirement = "identifier \"com.tgous.vpipe\" and anchor apple generic and certificate leaf[subject.OU] = \"72K6DYBTKN\""

    static func verifyRuntime(_ manifest: H3ReferenceEngineManifest) throws {
        let bundle = try H3Files.safe(manifest.bundlePath)
        guard try WorkspaceDigest.sha256(H3Files.safe(manifest.packagePath)) == packageSHA,
              try WorkspaceDigest.sha256(H3Files.inside(bundle.path + "/Contents/Helpers/vpipe",bundle.path)) == helperSHA,
              try WorkspaceDigest.sha256(H3Files.inside(bundle.path + "/Contents/Frameworks/libvpipe.0.dylib",bundle.path)) == librarySHA,
              let plist = try PropertyListSerialization.propertyList(from:H3Files.read(bundle.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any],
              plist["CFBundleVersion"] as? String == "80",plist["CFBundleIdentifier"] as? String == "com.tgous.vpipe" else {
            throw StudioError.invalid("隔离引擎包、原生程序或依赖库指纹不同。")
        }
        var code: SecStaticCode?,requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL,[],&code) == errSecSuccess,
              SecRequirementCreateWithString(vendorRequirement as CFString,[],&requirement) == errSecSuccess,
              let code,let requirement,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckNestedCode),requirement) == errSecSuccess else {
            throw StudioError.invalid("隔离引擎的官方签名或嵌套资源验证失败；未执行。")
        }
    }

    static func modelStamps(workDirectory: String) throws -> [H3ReferenceModelStamp] {
        let root = try H3Files.inside(workDirectory + "/models/local/MiniMax-H3-FL2VA-8bit/text_encoders",workDirectory)
        let configURL = root.appendingPathComponent("config.json"),indexURL = root.appendingPathComponent("model.safetensors.index.json")
        let config = try H3Files.read(configURL),index = try H3Files.read(indexURL)
        guard let cfg = try JSONSerialization.jsonObject(with:config) as? [String:Any],cfg["model_type"] as? String == "qwen3_vl",
              let object = try JSONSerialization.jsonObject(with:index) as? [String:Any],let weights = object["weight_map"] as? [String:String] else {
            throw StudioError.invalid("现有本机模型缺少Qwen3-VL参考编码配置；不会补下载。")
        }
        let vision = weights.filter { $0.key.hasPrefix("visual.") }
        guard vision.count == 351,vision["visual.patch_embed.proj.weight"] != nil else {
            throw StudioError.invalid("现有模型缺少完整的351项视觉权重；不会用文本编码冒充图片参考。")
        }
        var stamps = [H3ReferenceModelStamp(path:configURL.path,size:UInt64(config.count),metadataSHA256:H3ABConfigurationReader.digest(config)),
                      H3ReferenceModelStamp(path:indexURL.path,size:UInt64(index.count),metadataSHA256:H3ABConfigurationReader.digest(index))]
        for name in Set(weights.values).sorted() {
            guard name == URL(fileURLWithPath:name).lastPathComponent,name.hasSuffix(".safetensors") else { throw StudioError.invalid("模型分片名称无效。") }
            let url = try H3Files.inside(root.path + "/" + name,root.path)
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,let size = (attributes[.size] as? NSNumber)?.uint64Value else { throw StudioError.invalid("模型分片不完整。") }
            let handle = try FileHandle(forReadingFrom:url);defer { try? handle.close() }
            guard let length = try handle.read(upToCount:8),length.count == 8 else { throw StudioError.invalid("模型分片头缺失。") }
            let count = length.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
            guard count > 0,count <= 16_777_216,count+8 < size,
                  let header = try handle.read(upToCount:Int(count)),header.count == Int(count),
                  let tensors = try JSONSerialization.jsonObject(with:header) as? [String:Any] else { throw StudioError.invalid("模型分片头无效。") }
            for (key,_) in weights where weights[key] == name {
                guard let tensor = tensors[key] as? [String:Any],let offsets = tensor["data_offsets"] as? [UInt64],offsets.count == 2,
                      offsets[0] < offsets[1],offsets[1] <= size-count-8 else { throw StudioError.invalid("本机模型缺失或截断权重：" + key) }
            }
            if let patch = tensors["visual.patch_embed.proj.weight"] as? [String:Any] {
                guard patch["shape"] as? [Int] == [1152,3,2,16,16],patch["dtype"] as? String == "BF16" else { throw StudioError.invalid("视觉编码器结构与固定引擎不匹配。") }
            }
            stamps.append(.init(path:url.path,size:size,metadataSHA256:H3ABConfigurationReader.digest(header)))
        }
        return stamps
    }

    static func canUse(_ binding: H3ReferenceEngineBinding?,job: ShotJob) -> Bool {
        guard let binding,(try? binding.manifest.validateScope(job.id)) != nil,job.shot == 26 else { return false }
        return (job.h3FidelityChecks ?? []).filter { $0.referenceEngine != nil }.count < binding.manifest.maximumTrials
    }

    static func prepareSession(workDirectory: String,diagnosticDirectory: String) throws -> (directory: URL,config: URL,registrySHA256: String) {
        // The global GPU lease must already be owned. Copy the small native
        // registry, never edit it or let the new engine open the old database.
        // Its registered model paths remain absolute and reuse existing files.
        let source = try H3Files.inside(workDirectory + "/data.mdb",workDirectory)
        let bytes = try H3Files.read(source),hash = H3ABConfigurationReader.digest(bytes)
        let directory = try H3Files.inside(diagnosticDirectory + "/native-session",diagnosticDirectory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        let copy = directory.appendingPathComponent("data.mdb")
        try bytes.write(to:copy,options:.withoutOverwriting)
        guard try WorkspaceDigest.sha256(source) == hash,try WorkspaceDigest.sha256(copy) == hash else {
            throw StudioError.invalid("原生模型登记在隔离快照时变化；未执行新版引擎。")
        }
        let config = directory.appendingPathComponent("session.json")
        try JSONSerialization.data(withJSONObject:["db":["path":directory.path]],options:[.sortedKeys,.prettyPrinted]).write(to:config,options:.withoutOverwriting)
        return (directory,config,hash)
    }

    static func prompt(_ proposal: H3FirstProposal) -> String {
        "<Subject 1> is the single three-headed, six-armed figure with the same three faces, hairstyles, clothing, one spear and two complete fire wheels shown in <Picture 1>. The dragon, water, terrain, framing and all existing objects must match <Picture 1>.\n\n[reference generation] " + proposal.prompt
    }
}

extension TaskStore {
    func registerReferenceEngine(_ url: URL,jobID: UUID) async throws {
        guard singleGeneratorIdle,h3Runtime.mode == .real,
              let index = state.jobs.firstIndex(where:{ $0.id == jobID }),state.jobs[index].shot == 26,
              state.jobs[index].status == .completed,state.jobs[index].supersededBy == nil,
              state.jobs[index].h3VideoRejection != nil,state.jobs[index].h3ReferenceEngine == nil,
              let proposal = state.jobs[index].h3Binding?.appFirstTask?.proposal,proposal.reviewReady,
              H3Fidelity.comparisonBaseline(for:.motionReferenceDetail,in:state.jobs[index],originalSHA256:proposal.input!.originalSHA256) != nil else {
            throw StudioError.invalid("需要第26镜同图首尾对照的漂移记录、空闲GPU和未重复登记的隔离引擎。")
        }
        fidelityJobID = jobID;fidelityPreparing = true
        defer { fidelityJobID = nil;fidelityPreparing = false }
        let bytes = try H3Files.read(H3Files.safe(url.path)),manifest = try JSONDecoder().decode(H3ReferenceEngineManifest.self,from:bytes)
        try manifest.validateScope(jobID)
        let stamps = try await Task.detached(priority:.utility) {
            try H3ReferenceEngine.verifyRuntime(manifest)
            return try H3ReferenceEngine.modelStamps(workDirectory:proposal.workDirectory)
        }.value
        guard !shuttingDown,fidelityJobID == jobID,state.jobs[index].h3ReferenceEngine == nil else { throw StudioError.invalid("隔离引擎登记已取消。") }
        let directory = try H3Files.inside(root.path + "/h3-reference-engines/" + jobID.uuidString + "/" + UUID().uuidString,root.path)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(state.jobs[index]).write(to:directory.appendingPathComponent("previous-job.json"),options:.withoutOverwriting)
        try bytes.write(to:directory.appendingPathComponent("imported-manifest.json"),options:.withoutOverwriting)
        let now = Date(),receipt = directory.appendingPathComponent("registration.json")
        let payload: [String:Any] = ["schema":"jingsheng-isolated-reference-engine-registration-v1","manifest":try JSONSerialization.jsonObject(with:encoder.encode(manifest)),
            "modelStamps":try JSONSerialization.jsonObject(with:encoder.encode(stamps)),"sourceSHA256":H3ABConfigurationReader.digest(bytes),
            "modelStampScope":"configuration, weight index, shard header and file length; not full weight rehash",
            "registeredAt":ISO8601DateFormatter().string(from:now),"source":"AppUI","videoAccepted":false,"newModelsDownloaded":false]
        let receiptBytes = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys,.prettyPrinted])
        try receiptBytes.write(to:receipt,options:.withoutOverwriting)
        state.jobs[index].h3ReferenceEngine = .init(manifest:manifest,receiptPath:receipt.path,receiptSHA256:H3ABConfigurationReader.digest(receiptBytes),modelStamps:stamps,registeredAt:now)
        state.jobs[index].logTail.append("App登记隔离Vpipe 0.1.80；沿用现有模型，最多两条22帧对照，原任务引擎绑定不变。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "隔离引擎及现有视觉权重已核对；登记没有启动生成。"
    }
}
