import Foundation
import ImageIO
import Darwin

enum H3FidelityKind: String, Codable, CaseIterable, Identifiable {
    case codecBaseline, codecDetail, motionDetail, motionBaseDetail, motionKeyframeDetail, motionReferenceDetail, motionIsolatedBaseline, motionPairedKeyframes
    var id: String { rawValue }
    var width: Int { self == .codecBaseline ? 768 : 1536 }
    var height: Int { self == .codecBaseline ? 448 : 896 }
    var frames: Int { 22 }
    var isMotion: Bool { self == .motionDetail || usesBaseModel }
    var usesIsolatedEngine: Bool { self == .motionReferenceDetail || self == .motionIsolatedBaseline }
    var usesBaseModel: Bool { self == .motionBaseDetail || self == .motionKeyframeDetail || self == .motionPairedKeyframes || usesIsolatedEngine }
    var comparisonKind: Self? {
        switch self {
        case .motionBaseDetail: return .motionDetail
        case .motionKeyframeDetail: return .motionBaseDetail
        case .motionReferenceDetail: return .motionKeyframeDetail
        case .motionIsolatedBaseline: return .motionBaseDetail
        case .motionPairedKeyframes: return .motionKeyframeDetail
        default: return nil
        }
    }
    var maximumSeconds: TimeInterval { self == .motionKeyframeDetail || self == .motionPairedKeyframes || usesIsolatedEngine ? 2400 : 1800 }
    func steps(_ proposal: H3FirstProposal) -> Int { usesBaseModel ? 8 : (isMotion ? proposal.profile.steps : 0) }
    var title: String {
        switch self {
        case .codecBaseline: return "768 编解码对照"
        case .codecDetail: return "1536 编解码对照"
        case .motionDetail: return "1536 短段保真对照"
        case .motionBaseDetail: return "1536 原模型8步对照"
        case .motionKeyframeDetail: return "1536 首尾同图对照"
        case .motionReferenceDetail: return "1536 隔离引擎参考图对照"
        case .motionIsolatedBaseline: return "1536 新引擎单首帧基线"
        case .motionPairedKeyframes: return "1536 不同首尾姿态对照"
        }
    }
}

struct H3FidelityBaseline: Codable, Equatable {
    var diagnosticID: UUID
    var reportSHA256: String
    var observationSHA256: String
}

struct H3FidelityRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: H3FidelityKind
    var directory: String
    var requestSHA256: String
    var originalSHA256: String
    var recipeVersion = H3Fidelity.recipeVersion
    var status = "starting"
    var stage = "核对原始输入"
    var startedAt = Date()
    var endedAt: Date?
    var worker: ProcessIdentity?
    var reportSHA256: String?
    var error: String?
    var observation: String?
    var observationSHA256: String?
    var finding: H3FidelityFinding?
    var guidance: H3FidelityGuidance?
    var progress: StageProgress?
    var baseline: H3FidelityBaseline?
    var referenceEngine: H3ReferenceEngineBinding?
    var referenceTrial: H3FidelityBaseline?
    var referenceTrialPolicy: H3ReferenceTrialPolicyBinding?
    var pairedInput: H3FidelityPairBinding?
    var isActive: Bool { ["starting","running","cancelling"].contains(status) }
    var inputPath: String { directory + "/input.png" }
    var reportPath: String { directory + "/report.json" }
    var clipPath: String? { kind.isMotion && status == "completed" ? directory + "/trial.mp4" : nil }
    func framePath(_ index: Int) -> String { directory + String(format:"/frames/frame-%04d.png",index) }
}

struct H3FidelityRequest: Codable {
    var schema = "jingsheng-App-fidelity-diagnostic-v1"
    var recipeVersion = H3Fidelity.recipeVersion
    var id: UUID
    var appJobID: UUID
    var workspace: String
    var owner: ProcessIdentity
    var sessionID: UUID
    var kind: H3FidelityKind
    var binding: H3Binding
    var appExecutableSHA256: String
    var baseline: H3FidelityBaseline?
    var referenceEngine: H3ReferenceEngineBinding?
    var referenceTrial: H3FidelityBaseline?
    var referenceTrialPolicy: H3ReferenceTrialPolicyBinding?
    var pairedInput: H3FidelityPairBinding?
    var directory: String { workspace + "/h3-fidelity/" + appJobID.uuidString + "/" + id.uuidString }
    var url: URL { URL(fileURLWithPath:directory + "/request.json") }
    func ownerPresent() -> Bool {
        owner.stillSameProcess && (try? JSONDecoder().decode(UUID.self,from:H3Files.read(URL(fileURLWithPath:workspace + "/owner.json"),limit:1024))) == sessionID
    }
    func validate(_ bytes: Data) throws -> H3FirstProposal {
        guard schema == "jingsheng-App-fidelity-diagnostic-v1",recipeVersion == H3Fidelity.recipeVersion,binding.runtime == .real,
              binding.appTaskID == appJobID,binding.appTaskWorkspace == workspace,
              try WorkspaceDigest.sha256(H3Files.safe(binding.jobPath)) == binding.jobSHA256 else {
            throw StudioError.invalid("保真对照未绑定本 App 的原始任务。")
        }
        _ = try H3Files.inside(directory,workspace + "/h3-fidelity")
        let saved = try JSONDecoder().decode(WorkspaceState.self,from:H3Files.read(H3Files.safe(workspace + "/state.json"),limit:20_971_520))
        guard let parent = saved.jobs.first(where:{ $0.id == appJobID }),
              let record = parent.h3FidelityChecks?.first(where:{ $0.id == id }),record.isActive,
              record.directory == directory,record.kind == kind,record.recipeVersion == recipeVersion,
              record.baseline == baseline,
              record.referenceEngine == referenceEngine,
              record.referenceTrial == referenceTrial,
              record.referenceTrialPolicy == referenceTrialPolicy,
              record.pairedInput == pairedInput,
              record.requestSHA256 == H3ABConfigurationReader.digest(bytes),
              parent.status != .cancelled,parent.supersededBy == nil,
              let proposal = binding.appFirstTask?.proposal,proposal.input?.originalSHA256 == record.originalSHA256,
              proposal.pixelReview?.status == "pass",proposal.reviewBindingsMatch else {
            throw StudioError.invalid("保真对照缺少当前任务的输入检查或持久投递记录。")
        }
        let verified = try H3FirstTaskBinding.load(H3Files.safe(binding.jobPath),runtime:.real,requireFresh:false,allowHistoricalAcceptance:true).0
        guard verified.jobSHA256 == binding.jobSHA256,verified.appTaskID == appJobID else {
            throw StudioError.invalid("原任务身份变化，未开始保真对照。")
        }
        if kind == .motionPairedKeyframes {
            guard let pairedInput,parent.h3FidelityPairs?.last == pairedInput else { throw StudioError.invalid("不同姿态请求与当前A/B图审绑定不同。") }
            try pairedInput.validate(jobID:appJobID,binding:binding,workspace:workspace,requireReview:true)
        } else if pairedInput != nil { throw StudioError.invalid("旧对照不能冒用新A/B输入。") }
        if kind.usesIsolatedEngine {
            guard let referenceEngine,referenceEngine == parent.h3ReferenceEngine,parent.shot == 26 else {
                throw StudioError.invalid("参考对照未绑定App隔离引擎登记。")
            }
            try H3ReferenceEngine.validateTrialAllowance(referenceEngine,job:parent,workspace:workspace,policy:referenceTrialPolicy,includingCurrent:true)
            try referenceEngine.validate(jobID:appJobID,workspace:workspace,workDirectory:proposal.workDirectory)
        } else if referenceEngine != nil || referenceTrialPolicy != nil { throw StudioError.invalid("旧对照不能覆盖原任务引擎。") }
        if kind == .motionIsolatedBaseline {
            guard let referenceTrial,let referenceEngine,
                  referenceTrial == H3Fidelity.referenceTrialEvidence(in:parent,originalSHA256:record.originalSHA256),
                  let prior = parent.h3FidelityChecks?.first(where:{ $0.id == referenceTrial.diagnosticID }) else {
                throw StudioError.invalid("新版首帧基线需要已完成且记录漂移的同图参考试验，不能跳过检查。")
            }
            _ = try H3Fidelity.validateReport(prior,appJobID:appJobID)
            try H3Fidelity.validateReferenceEvidence(referenceTrial,appJobID:appJobID,originalSHA256:record.originalSHA256,
                engine:referenceEngine,parentDirectory:URL(fileURLWithPath:directory).deletingLastPathComponent().path)
        } else if referenceTrial != nil { throw StudioError.invalid("此方案不能冒用参考试验复核依据。") }
        if let comparisonKind = kind.comparisonKind {
            guard let baseline,baseline == H3Fidelity.comparisonBaseline(for:kind,in:parent,originalSHA256:record.originalSHA256),
                  let prior = parent.h3FidelityChecks?.first(where:{ $0.id == baseline.diagnosticID }),
                  try WorkspaceDigest.sha256(H3Files.inside(prior.directory + "/visual-observation.json",prior.directory)) == baseline.observationSHA256 else {
                throw StudioError.invalid("原模型对照缺少已核对的同输入运动漂移证据。")
            }
            _ = try H3Fidelity.validateReport(prior,appJobID:appJobID)
            _ = try H3Fidelity.comparisonInputHash(baseline,proposal:proposal,directory:prior.directory,kind:comparisonKind)
        } else if baseline != nil { throw StudioError.invalid("此对照类型不能冒用原模型比较记录。") }
        return proposal
    }
}

enum H3Fidelity {
    // The installed native VAE cannot decode a one-frame anchor. Its encoder
    // processes 17-pixel-frame chunks and drops 3 latent frames: 34 identical
    // input frames produce 7 latent frames, which decode to 22 pixel frames.
    // This is a STATIC clip round trip, never a generated-motion result.
    static let recipeVersion = 2
    static let codecInputFrames = 34
    static func referenceTrialEvidence(in job: ShotJob,originalSHA256: String) -> H3FidelityBaseline? {
        guard let engine = job.h3ReferenceEngine,
              let prior = job.h3FidelityChecks?.last(where:{
                  $0.kind == .motionReferenceDetail && $0.status == "completed" && $0.finding == .motionIdentityDrift &&
                  $0.recipeVersion == recipeVersion && $0.originalSHA256 == originalSHA256 && $0.referenceEngine == engine
              }),let report = prior.reportSHA256,let observation = prior.observationSHA256,
              ModelStatusReader.isHash(report,length:64),ModelStatusReader.isHash(observation,length:64) else { return nil }
        return .init(diagnosticID:prior.id,reportSHA256:report,observationSHA256:observation)
    }
    static func validateReferenceEvidence(_ proof: H3FidelityBaseline,appJobID: UUID,originalSHA256: String,
                                         engine: H3ReferenceEngineBinding,parentDirectory: String) throws {
        let directory = parentDirectory + "/" + proof.diagnosticID.uuidString
        let bytes = try H3Files.read(H3Files.inside(directory + "/report.json",directory))
        let observation = try H3Files.read(H3Files.inside(directory + "/visual-observation.json",directory))
        guard H3ABConfigurationReader.digest(bytes) == proof.reportSHA256,
              H3ABConfigurationReader.digest(observation) == proof.observationSHA256,
              let report = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let note = try JSONSerialization.jsonObject(with:observation) as? [String:Any],
              report["diagnosticID"] as? String == proof.diagnosticID.uuidString,
              note["diagnosticID"] as? String == proof.diagnosticID.uuidString,
              report["appJobID"] as? String == appJobID.uuidString,note["appJobID"] as? String == appJobID.uuidString,
              report["originalSHA256"] as? String == originalSHA256,note["originalSHA256"] as? String == originalSHA256,
              report["kind"] as? String == H3FidelityKind.motionReferenceDetail.rawValue,
              report["engineRegistrationSHA256"] as? String == engine.receiptSHA256,
              note["reportSHA256"] as? String == proof.reportSHA256,
              note["finding"] as? String == H3FidelityFinding.motionIdentityDrift.rawValue,
              report["videoAccepted"] as? Bool == false,note["videoAccepted"] as? Bool == false else {
            throw StudioError.invalid("参考试验的任务、图像、引擎、报告或漂移结论不一致，未使用剩余授权。")
        }
    }
    static func baseMotionBaseline(in job: ShotJob,originalSHA256: String) -> H3FidelityBaseline? {
        comparisonBaseline(for:.motionBaseDetail,in:job,originalSHA256:originalSHA256)
    }
    static func comparisonBaseline(for kind: H3FidelityKind,in job: ShotJob,originalSHA256: String) -> H3FidelityBaseline? {
        guard let comparisonKind = kind.comparisonKind else { return nil }
        guard let prior = job.h3FidelityChecks?.last(where:{
            $0.kind == comparisonKind && $0.status == "completed" && $0.finding == .motionIdentityDrift &&
            $0.recipeVersion == recipeVersion && $0.originalSHA256 == originalSHA256
        }),let report = prior.reportSHA256,let observation = prior.observationSHA256,
              ModelStatusReader.isHash(report,length:64),ModelStatusReader.isHash(observation,length:64) else { return nil }
        return .init(diagnosticID:prior.id,reportSHA256:report,observationSHA256:observation)
    }
    static func comparisonInputHash(_ baseline: H3FidelityBaseline,proposal: H3FirstProposal,directory: String,kind: H3FidelityKind = .motionDetail) throws -> String {
        let bytes = try H3Files.read(H3Files.inside(directory + "/report.json",directory))
        let graph = try H3Files.read(H3Files.inside(directory + "/pipeline.vpipeline",directory))
        guard H3ABConfigurationReader.digest(bytes) == baseline.reportSHA256,
              let report = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              report["diagnosticID"] as? String == baseline.diagnosticID.uuidString,
              report["kind"] as? String == kind.rawValue,
              report["seed"] as? Int == proposal.seed,report["promptSHA256"] as? String == proposal.promptSHA256,
              report["steps"] as? Int == kind.steps(proposal),
              graph == (try pipeline(kind:kind,proposal:proposal,directory:directory)),
              report["pipelineSHA256"] as? String == H3ABConfigurationReader.digest(graph),
              let input = report["inputSHA256"] as? String,
              input == (try WorkspaceDigest.sha256(H3Files.inside(directory + "/input.png",directory))) else {
            throw StudioError.invalid("旧运动对照的输入、种子、提示词或管线不同，不能作为本次比较基线。")
        }
        return input
    }
    static func pipeline(kind: H3FidelityKind,proposal: H3FirstProposal,directory: String,pairedInput: H3FidelityPairBinding? = nil) throws -> Data {
        let template = try H3Files.readTemplateFallback()
        guard H3ABConfigurationReader.digest(template) == H3ABTaskBinding.templateSHA256 else { throw StudioError.invalid("保真管线模板指纹不同。") }
        var p = proposal
        if kind == .motionPairedKeyframes {
            guard let pairedInput,pairedInput.reviewed else { throw StudioError.invalid("不同A/B缺少通过的助手图审。") }
            p.prompt = pairedInput.receipt.plan.prompt;p.promptSHA256 = pairedInput.receipt.plan.promptSHA256
        } else if pairedInput != nil { throw StudioError.invalid("旧管线不能使用不同A/B图。") }
        p.profile.width = kind.width;p.profile.height = kind.height;p.profile.frames = kind.frames
        if kind.isMotion { p.profile.steps = kind.steps(proposal) }
        var graph = try JSONSerialization.jsonObject(with:H3FirstTaskBinding.pipeline(template:template,id:URL(fileURLWithPath:directory).lastPathComponent,
            proposal:p,first:directory + "/input.png",directory:directory)) as! [String:Any]
        let codecStages = Set(["model-select","load-A","vae-encode-A","vae-decode","save-detail-frames"])
        var result: [[String:Any]] = []
        for var stage in graph["stages"] as! [[String:Any]] {
            let id = stage["id"] as! String
            if !kind.isMotion && !codecStages.contains(id) { continue }
            // The input has already been prepared at the requested size by the
            // App from the ORIGINAL. Never upscale a generated frame or run an
            // implicit crop/resample stage a second time.
            if id == "normalize-A" || id == "save-detail-source" { continue }
            if kind == .motionReferenceDetail && ["diffusion-conditioner","vae-encode-A"].contains(id) { continue }
            var config = stage["config"] as! [String:Any]
            if kind == .motionReferenceDetail && id == "text-prompt" { config["text"] = H3ReferenceEngine.prompt(proposal) }
            if id == "load-A" && !kind.isMotion {
                config["url"] = Array(repeating:directory + "/input.png",count:codecInputFrames)
            }
            if id == "vae-encode-A" {
                if !kind.isMotion {
                    result.append(["id":"stack-static-clip","type":"temporal-stack",
                        "iports":[["src":"load-A","oport":0]],
                        "config":["mode":"video","group_size":codecInputFrames,"overlap":0,"max_mb":192,"fps":24]])
                }
                stage["iports"] = [["src":kind.isMotion ? "load-A" : "stack-static-clip","oport":0],["src":"model-select","oport":0]]
            }
            if id == "vae-decode" && !kind.isMotion { stage["iports"] = [["src":"vae-encode-A","oport":0],["src":"model-select","oport":0]] }
            if id == "minimax-h3-model-config" && kind.usesBaseModel {
                config.removeValue(forKey:"lora");config.removeValue(forKey:"lora_scale")
                config.removeValue(forKey:"linear_branch")
            }
            if kind == .motionReferenceDetail && id == "generate-video" {
                result.append(["id":"video-ref-encoder","type":"video-ref-encoder",
                    "iports":[["src":"text-prompt","oport":0],["src":"model-select","oport":0],["src":"load-A","oport":0]],
                    "config":["frames":kind.frames,"reference_image_short_edge":768,"unload_when_idle":"always"]])
                var ports = stage["iports"] as! [[String:Any]]
                ports[0] = ["src":"video-ref-encoder","oport":0]
                ports[5] = ["src":"","oport":0];ports[6] = ["src":"","oport":0]
                ports[7] = ["src":"video-ref-encoder","oport":1];ports[8] = ["src":"video-ref-encoder","oport":2]
                stage["iports"] = ports
            }
            if id == "generate-video" && kind == .motionKeyframeDetail {
                // Same prepared image, encoded once and delivered to BOTH
                // keyframe inputs. This changes only the end conditioning;
                // it is not a supplied contact pose or a continuous face lock.
                var ports = stage["iports"] as! [[String:Any]]
                ports[6] = ["src":"vae-encode-A","oport":0]
                stage["iports"] = ports
            }
            if id == "generate-video" && kind == .motionPairedKeyframes {
                // Both images have already been contained from their originals
                // and reviewed. B is a real final-pose latent, not gallery data.
                guard let loadA = result.first(where:{ $0["id"] as? String == "load-A" }),
                      let vaeA = result.first(where:{ $0["id"] as? String == "vae-encode-A" }) else { throw StudioError.invalid("缺少可复用的首尾编码阶段。") }
                var loadB = loadA,vaeB = vaeA,loadConfig = loadA["config"] as! [String:Any]
                loadB["id"] = "load-B";loadConfig["url"] = [directory + "/input-B.png"];loadB["config"] = loadConfig
                vaeB["id"] = "vae-encode-B";vaeB["iports"] = [["src":"load-B","oport":0],["src":"model-select","oport":0]]
                result.append(loadB);result.append(vaeB)
                var ports = stage["iports"] as! [[String:Any]]
                ports[5] = ["src":"vae-encode-A","oport":0];ports[6] = ["src":"vae-encode-B","oport":0]
                stage["iports"] = ports
            }
            if id == "save-detail-frames" { config["path"] = directory + "/frames/frame-%04d.png" }
            if id == "save-video" { config["output_url"] = directory + "/trial.mp4" }
            stage["config"] = config;result.append(stage)
        }
        graph["stages"] = result
        return try JSONSerialization.data(withJSONObject:graph,options:[.sortedKeys,.prettyPrinted])
    }
    static func claim(_ url: URL,data: Data) throws {
        let fd = open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StudioError.invalid("单 GPU 已被占用；没有启动第二个进程，也未接管旧锁。") }
        let written = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,$0.count) },flushed = fsync(fd)
        close(fd)
        guard written == data.count,flushed == 0 else { throw StudioError.invalid("单 GPU 锁写入不完整。") }
    }
    static func outputReceipts(directory: String,kind: H3FidelityKind) throws -> [[String:Any]] {
        let root = try H3Files.safe(directory + "/frames")
        let names = try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()
        let expected = (0..<kind.frames).map { String(format:"frame-%04d.png",$0) }
        guard names == expected else { throw StudioError.invalid("保真输出帧数不符：期望 \(kind.frames)，实际 \(names.count)。保留诊断，不重试。") }
        return try names.enumerated().map { index,name in
            let path = try H3Files.inside(root.path + "/" + name,root.path)
            let hash = try WorkspaceDigest.sha256(path)
            try H3SourceFrames.technicalImage(path.path,hash:hash,width:kind.width,height:kind.height)
            return ["rawIndex":index,"path":path.path,"sha256":hash]
        }
    }
    static func validateReport(_ record: H3FidelityRecord,appJobID: UUID) throws -> Data {
        let bytes = try H3Files.read(H3Files.inside(record.reportPath,record.directory))
        guard record.reportSHA256 == nil || record.reportSHA256 == H3ABConfigurationReader.digest(bytes),
              let report = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              report["diagnosticID"] as? String == record.id.uuidString,report["appJobID"] as? String == appJobID.uuidString,
              report["kind"] as? String == record.kind.rawValue,report["recipeVersion"] as? Int == record.recipeVersion,
              report["requestSHA256"] as? String == record.requestSHA256,
              report["originalSHA256"] as? String == record.originalSHA256,report["videoAccepted"] as? Bool == false,
              report["continuationAuthorized"] as? Bool == false,report["status"] as? String == "technical_complete_visual_review_required",
              report["inputSHA256"] as? String == (try WorkspaceDigest.sha256(H3Files.inside(record.inputPath,record.directory))),
              let declared = report["frames"] as? [[String:Any]] else { throw StudioError.invalid("对照报告、输入或任务指纹不同。") }
        let actual = try outputReceipts(directory:record.directory,kind:record.kind)
        guard try JSONSerialization.data(withJSONObject:declared,options:.sortedKeys) == JSONSerialization.data(withJSONObject:actual,options:.sortedKeys) else {
            throw StudioError.invalid("对照图像已变化，不能将当前像素记到旧报告。")
        }
        if record.kind.isMotion {
            guard report["clipSHA256"] as? String == (try WorkspaceDigest.sha256(H3Files.inside(record.directory + "/trial.mp4",record.directory))) else { throw StudioError.invalid("对照视频已变化。") }
        }
        if let comparisonKind = record.kind.comparisonKind {
            let requestBytes = try H3Files.read(H3Files.inside(record.directory + "/request.json",record.directory))
            let request = try JSONDecoder().decode(H3FidelityRequest.self,from:requestBytes)
            guard H3ABConfigurationReader.digest(requestBytes) == record.requestSHA256,
                  request.id == record.id,request.appJobID == appJobID,request.kind == record.kind,
                  request.baseline != nil,request.baseline == record.baseline,
                  request.referenceEngine == record.referenceEngine,
                  request.referenceTrial == record.referenceTrial,
                  request.referenceTrialPolicy == record.referenceTrialPolicy,
                  request.pairedInput == record.pairedInput,
                  let proposal = request.binding.appFirstTask?.proposal else { throw StudioError.invalid("原模型对照请求或比较基线发生变化。") }
            let actual = try H3Files.read(H3Files.inside(record.directory + "/pipeline.vpipeline",record.directory))
            let expected = try pipeline(kind:record.kind,proposal:proposal,directory:record.directory,pairedInput:request.pairedInput)
            guard actual == expected,report["pipelineSHA256"] as? String == H3ABConfigurationReader.digest(actual),
                  report["steps"] as? Int == 8,report["turboAdapterUsed"] as? Bool == false,
                  report["seed"] as? Int == proposal.seed,report["promptSHA256"] as? String == proposal.promptSHA256,
                  report["baselineDiagnosticID"] as? String == record.baseline!.diagnosticID.uuidString,
                  report["baselineReportSHA256"] as? String == record.baseline!.reportSHA256,
                  report["baselineObservationSHA256"] as? String == record.baseline!.observationSHA256 else {
                throw StudioError.invalid("原模型对照必须保持同图、同种子与提示词，使用8步且不加载Turbo。")
            }
            let priorDirectory = URL(fileURLWithPath:record.directory).deletingLastPathComponent().appendingPathComponent(record.baseline!.diagnosticID.uuidString).path
            guard report["inputSHA256"] as? String == (try comparisonInputHash(record.baseline!,proposal:proposal,directory:priorDirectory,kind:comparisonKind)) else {
                throw StudioError.invalid("两个运动对照没有使用完全相同的输入像素。")
            }
            if record.kind == .motionKeyframeDetail {
                guard report["sameImageAtBothKeyframes"] as? Bool == true,
                      report["lastKeyframeInputSHA256"] as? String == report["inputSHA256"] as? String,
                      report["persistentIdentityReferenceUsed"] as? Bool == false else {
                    throw StudioError.invalid("首尾同图对照缺少真实末帧绑定，不能冒称持续身份约束。")
                }
            }
            if record.kind == .motionPairedKeyframes {
                guard let pair = request.pairedInput else { throw StudioError.invalid("缺少实际不同首尾输入。") }
                try pair.validate(jobID:appJobID,binding:request.binding,workspace:request.workspace,requireReview:true)
                guard report["pairPreparationSHA256"] as? String == pair.receiptSHA256,
                      report["pairReviewSHA256"] as? String == pair.reviews.last?.sha256,
                      report["effectivePromptSHA256"] as? String == pair.receipt.plan.promptSHA256,
                      report["inputSHA256"] as? String == pair.receipt.firstNormalized.sha256,
                      report["lastKeyframeInputSHA256"] as? String == pair.receipt.lastNormalized.sha256,
                      report["lastKeyframeInputSHA256"] as? String == (try WorkspaceDigest.sha256(H3Files.inside(record.directory + "/input-B.png",record.directory))),
                      report["differentKeyframeImages"] as? Bool == true,report["persistentIdentityReferenceUsed"] as? Bool == false,
                      report["identityLockVerified"] as? Bool == false else { throw StudioError.invalid("不同首尾条件或实际Prompt未在报告中得到核验。") }
                let log = try H3Files.read(H3Files.inside(record.directory + "/native.log",record.directory))
                guard report["nativeLogSHA256"] as? String == H3ABConfigurationReader.digest(log) else { throw StudioError.invalid("不同姿态对照日志已改变。") }
                try validatePairedLog(String(decoding:log,as:UTF8.self))
            }
            if record.kind.usesIsolatedEngine {
                guard let engine = request.referenceEngine,
                      report["helperSHA256"] as? String == engine.manifest.helperSHA256,
                      report["librarySHA256"] as? String == engine.manifest.librarySHA256,
                      report["engineRegistrationSHA256"] as? String == engine.receiptSHA256,
                      report["nativeSessionDirectory"] as? String == record.directory + "/native-session",
                      report["originalNativeRegistryUnchanged"] as? Bool == true,
                      report["identityLockVerified"] as? Bool == false else { throw StudioError.invalid("参考对照缺少实际引擎、参考模式或提示词回执。") }
                try engine.manifest.validateScope(appJobID)
                if let policy = request.referenceTrialPolicy {
                    try policy.validate(jobID:appJobID,engine:engine,workspace:request.workspace)
                    guard report["trialPolicyReceiptSHA256"] as? String == policy.receiptSHA256 else {
                        throw StudioError.invalid("对照报告缺少本次用户次数设置回执。")
                    }
                } else if report["trialPolicyReceiptSHA256"] != nil {
                    throw StudioError.invalid("旧对照不能冒用后来的次数设置。")
                }
                let nativeLog = try H3Files.read(H3Files.inside(record.directory + "/native.log",record.directory))
                guard report["nativeLogSHA256"] as? String == H3ABConfigurationReader.digest(nativeLog) else {
                    throw StudioError.invalid("隔离引擎原生日志已改变。")
                }
                try validateIsolatedMode(record.kind,report:report,log:String(decoding:nativeLog,as:UTF8.self),proposal:proposal)
                if record.kind == .motionIsolatedBaseline {
                    guard let proof = request.referenceTrial,
                          report["referenceTrialID"] as? String == proof.diagnosticID.uuidString,
                          report["referenceTrialReportSHA256"] as? String == proof.reportSHA256,
                          report["referenceTrialObservationSHA256"] as? String == proof.observationSHA256 else {
                        throw StudioError.invalid("新版首帧基线缺少先前参考试验复核依据。")
                    }
                    try validateReferenceEvidence(proof,appJobID:appJobID,originalSHA256:record.originalSHA256,
                        engine:engine,parentDirectory:URL(fileURLWithPath:record.directory).deletingLastPathComponent().path)
                }
            }
        }
        return bytes
    }
    static func validatePairedLog(_ log: String) throws {
        guard log.contains("VaeEncodeStage('vae-encode-A')"),log.contains("VaeEncodeStage('vae-encode-B')"),
              log.contains("DiffusionConditionerStage('diffusion-conditioner')") else {
            throw StudioError.invalid("原生日志没有证明两张姿态图实际编码。")
        }
    }
    static func validateIsolatedMode(_ kind: H3FidelityKind,report: [String:Any],log: String,proposal: H3FirstProposal) throws {
        let isReference = kind == .motionReferenceDetail
        let expectedPrompt = isReference ? H3ReferenceEngine.prompt(proposal) : proposal.prompt
        guard kind.usesIsolatedEngine,
              report["effectivePromptSHA256"] as? String == H3ABConfigurationReader.digest(Data(expectedPrompt.utf8)),
              report["referenceMode"] as? String == (isReference ? "FL2VA-Ref2VA-like-zero-shot" : "FL2VA-single-first-frame-baseline"),
              report["exactFirstFrameConditioning"] as? Bool == !isReference else {
            throw StudioError.invalid("隔离引擎条件模式或实际Prompt不同。")
        }
        let referenceMarker = "1 reference on the FL2VA partition -- upstream's Ref2VA-like mode"
        guard isReference ? log.contains(referenceMarker) :
                (log.contains("VaeEncodeStage('vae-encode-A')") && log.contains("DiffusionConditionerStage('diffusion-conditioner')") && !log.contains(referenceMarker)) else {
            throw StudioError.invalid("原生日志没有证明本次实际条件路径。")
        }
    }
}

private var fidelityStop: Int32 = 0
private final class H3FidelityLog {
    private let lock = NSLock()
    private let handle: FileHandle
    private var failure: String?
    init(_ url: URL) throws {
        try Data().write(to:url,options:.withoutOverwriting);handle = try FileHandle(forWritingTo:url)
    }
    func append(_ line: String) {
        lock.lock();defer { lock.unlock() }
        do { try handle.write(contentsOf:Data((line + "\n").utf8)) } catch { failure = error.localizedDescription }
        if line.range(of:#"\[ERROR\]|out of memory|bad_alloc|Permission denied|Operation not permitted|unknown stage"#,options:[.regularExpression,.caseInsensitive]) != nil { failure = String(line.prefix(1200)) }
    }
    var error: String? { lock.lock();defer { lock.unlock() };return failure }
    func close() { lock.lock();defer { lock.unlock() };try? handle.close() }
}

enum H3FidelityWorker {
    static func run(_ url: URL) -> Int32 {
        signal(SIGTERM) { _ in fidelityStop = 1 };signal(SIGINT) { _ in fidelityStop = 1 };signal(SIGPIPE,SIG_IGN)
        var request: H3FidelityRequest?,child: H3ChildProcess?,scope: OwnedProcessScope?,log: H3FidelityLog?
        var lease: URL?,leaseBytes: Data?
        defer {
            log?.close()
            if let lease,let leaseBytes,(try? H3Files.read(lease,limit:4096)) == leaseBytes { try? FileManager.default.removeItem(at:lease) }
        }
        do {
            let data = try H3Files.read(H3Files.safe(url.path)),r = try JSONDecoder().decode(H3FidelityRequest.self,from:data)
            request = r
            guard r.url == url,r.ownerPresent(),try WorkspaceDigest.sha256(URL(fileURLWithPath:CommandLine.arguments[0])) == r.appExecutableSHA256 else {
                throw StudioError.invalid("保真监督器、App 会话或请求路径身份不同。")
            }
            let proposal = try r.validate(data),input = proposal.input!,kind = r.kind
            guard !ProcessInfo.processInfo.environment.keys.contains(where:{ $0.hasPrefix("VPIPE_H3") || $0.hasPrefix("VPIPE_MINIMAX_H3") }) else { throw StudioError.invalid("存在未记录的模型环境覆盖。") }
            guard case .success(let models) = ModelStatusReader.read(URL(fileURLWithPath:proposal.workDirectory)),
                  models.verification.quantization.state == .verified,models.verification.runtime.state == .verified else { throw StudioError.invalid("本机已注册模型尚未通过检查。") }
            let lockURL = try H3Files.inside(proposal.workDirectory + "/active-single-shot.lock",proposal.workDirectory)
            let available = try URL(fileURLWithPath:proposal.workDirectory).resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard available >= 20 * 1_073_741_824 else { throw StudioError.invalid("磁盘余量不足20 GiB，不开始保真对照。") }
            let lockData = try JSONSerialization.data(withJSONObject:["controller_pid":getpid(),"app_job_id":r.appJobID.uuidString,"diagnostic_id":r.id.uuidString,"session":r.sessionID.uuidString],options:.sortedKeys)
            try H3Fidelity.claim(lockURL,data:lockData);lease = lockURL;leaseBytes = lockData
            let directory = try H3Files.safe(r.directory)
            try data.write(to:directory.appendingPathComponent("attempt-once.json"),options:.withoutOverwriting)
            guard r.ownerPresent(),fidelityStop == 0 else { throw H3PreprocessingCancelled() }
            try H3SourceFrames.technicalImage(input.originalPath,hash:input.originalSHA256,width:input.originalWidth,height:input.originalHeight)
            let original = try H3Files.read(H3Files.safe(input.originalPath),limit:50_331_648)
            try original.write(to:directory.appendingPathComponent("original.png"),options:.withoutOverwriting)
            if let pair = r.pairedInput {
                for (image,name) in [(pair.receipt.firstNormalized,"input.png"),(pair.receipt.lastNormalized,"input-B.png"),(pair.receipt.lastOriginal,"original-B.png")] {
                    try image.validate(inside:pair.directory)
                    try H3Files.read(H3Files.safe(image.path),limit:50_331_648).write(to:directory.appendingPathComponent(name),options:.withoutOverwriting)
                }
            } else if kind == .codecBaseline {
                try H3SourceFrames.technicalImage(input.normalizedPath,hash:input.normalizedSHA256,width:768,height:448)
                try H3Files.read(H3Files.safe(input.normalizedPath),limit:50_331_648).write(to:directory.appendingPathComponent("input.png"),options:.withoutOverwriting)
            } else {
                guard let source = CGImageSourceCreateWithData(original as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw StudioError.invalid("原图无法解码。") }
                let normalized = try H3SourceFrames.contain(image,canvasWidth:kind.width,canvasHeight:kind.height)
                try H3SourceFrames.save(normalized.image,to:directory.appendingPathComponent("input.png"))
            }
            let inputHash = try WorkspaceDigest.sha256(directory.appendingPathComponent("input.png"))
            if let comparisonKind = kind.comparisonKind,let baseline = r.baseline {
                let priorDirectory = directory.deletingLastPathComponent().appendingPathComponent(baseline.diagnosticID.uuidString).path
                guard inputHash == (try H3Fidelity.comparisonInputHash(baseline,proposal:proposal,directory:priorDirectory,kind:comparisonKind)) else {
                    throw StudioError.invalid("本次归一输入与旧运动对照不同，未启动GPU。")
                }
            }
            let graph = try H3Fidelity.pipeline(kind:kind,proposal:proposal,directory:r.directory,pairedInput:r.pairedInput)
            let pipeline = directory.appendingPathComponent("pipeline.vpipeline")
            try graph.write(to:pipeline,options:.withoutOverwriting)
            try FileManager.default.createDirectory(at:directory.appendingPathComponent("frames"),withIntermediateDirectories:false)
            let logger = try H3FidelityLog(directory.appendingPathComponent("native.log"));log = logger
            let native = H3ChildProcess();child = native
            var arguments = ["--memory-cap-mb","12288","--wired-pool-mb","8192","--launch",pipeline.path]
            var nativeDirectory = URL(fileURLWithPath:proposal.workDirectory),registryHash: String?
            if kind.usesIsolatedEngine {
                let isolated = try H3ReferenceEngine.prepareSession(workDirectory:proposal.workDirectory,diagnosticDirectory:r.directory)
                nativeDirectory = isolated.directory;registryHash = isolated.registrySHA256
                arguments = ["--config",isolated.config.path] + arguments
            }
            H3Supervisor.emit(.init(type:"stage",stage:kind.title + " · 启动本机引擎"))
            // The old proposal remains immutable. Only this recorded diagnostic
            // request may select the explicitly registered alternate runtime.
            let helperPath = r.referenceEngine?.helperPath ?? proposal.helperPath
            try native.start(executable:URL(fileURLWithPath:helperPath),arguments:arguments,directory:nativeDirectory) { line,stderr in
                logger.append(line)
                if let event = H3Progress.event(line) { H3Supervisor.emit(event) }
            }
            let owned = try OwnedProcessScope(process:native.process);scope = owned
            let started = Date();var next = Date.distantPast
            while native.process.isRunning {
                if fidelityStop != 0 || !r.ownerPresent() { throw H3PreprocessingCancelled() }
                if let error = logger.error { throw StudioError.invalid(error) }
                guard Date().timeIntervalSince(started) < kind.maximumSeconds else { throw StudioError.invalid("保真对照超时，保留记录，不自动重试。") }
                if Date() >= next {
                    owned.refresh();H3Supervisor.emit(.init(type:"owned",ownedProcesses:owned.living));next = Date().addingTimeInterval(2)
                    var info = proc_taskinfo()
                    if proc_pidinfo(native.process.processIdentifier,PROC_PIDTASKINFO,0,&info,Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size,
                       info.pti_resident_size > 22 * 1_073_741_824 { throw StudioError.invalid("对照超过22 GiB内存保护，保留记录。") }
                }
                Thread.sleep(forTimeInterval:0.05)
            }
            native.process.waitUntilExit();native.drain();logger.close();log = nil
            guard native.process.terminationStatus == 0,logger.error == nil,fidelityStop == 0,r.ownerPresent() else { throw StudioError.invalid("保真原生执行未正常完成。") }
            let frames = try H3Fidelity.outputReceipts(directory:r.directory,kind:kind)
            guard try WorkspaceDigest.sha256(directory.appendingPathComponent("input.png")) == inputHash,
                  try WorkspaceDigest.sha256(pipeline) == H3ABConfigurationReader.digest(graph),
                  try WorkspaceDigest.sha256(H3Files.safe(input.originalPath)) == input.originalSHA256 else { throw StudioError.invalid("保真输入或管线在运行时变化。") }
            var report: [String:Any] = ["schema":"jingsheng-App-fidelity-report-v1","diagnosticID":r.id.uuidString,"appJobID":r.appJobID.uuidString,
                "kind":kind.rawValue,"status":"technical_complete_visual_review_required","originalSHA256":input.originalSHA256,"inputSHA256":inputHash,
                "recipeVersion":r.recipeVersion,"codecStaticInputFrames":kind.isMotion ? 0 : H3Fidelity.codecInputFrames,
                "sourceJobSHA256":r.binding.jobSHA256,"requestSHA256":H3ABConfigurationReader.digest(data),"pipelineSHA256":H3ABConfigurationReader.digest(graph),
                "appExecutableSHA256":r.appExecutableSHA256,"helperSHA256":r.referenceEngine?.manifest.helperSHA256 ?? proposal.helperSHA256,"librarySHA256":r.referenceEngine?.manifest.librarySHA256 ?? proposal.librarySHA256,
                "dimensions":[kind.width,kind.height],"frames":frames,"nativeExitCode":0,"promptSHA256":proposal.promptSHA256,"seed":proposal.seed,
                "steps":kind.steps(proposal),"motionGenerated":kind.isMotion,"videoAccepted":false,"continuationAuthorized":false,
                "inputFromOriginal":true,"upscaledGeneratedVideo":false,"command":arguments,"completedAt":ISO8601DateFormatter().string(from:Date())]
            if kind.comparisonKind != nil,let baseline = r.baseline {
                report["turboAdapterUsed"] = false
                report["baselineDiagnosticID"] = baseline.diagnosticID.uuidString
                report["baselineReportSHA256"] = baseline.reportSHA256
                report["baselineObservationSHA256"] = baseline.observationSHA256
            }
            if kind == .motionKeyframeDetail {
                report["sameImageAtBothKeyframes"] = true
                report["lastKeyframeInputSHA256"] = inputHash
                report["persistentIdentityReferenceUsed"] = false
            }
            if let pair = r.pairedInput {
                try pair.validate(jobID:r.appJobID,binding:r.binding,workspace:r.workspace,requireReview:true)
                guard try WorkspaceDigest.sha256(directory.appendingPathComponent("input-B.png")) == pair.receipt.lastNormalized.sha256 else { throw StudioError.invalid("末帧图在运行期间发生变化。") }
                let nativeLog = try H3Files.read(directory.appendingPathComponent("native.log"))
                try H3Fidelity.validatePairedLog(String(decoding:nativeLog,as:UTF8.self))
                report["nativeLogSHA256"] = H3ABConfigurationReader.digest(nativeLog)
                report["pairPreparationSHA256"] = pair.receiptSHA256
                report["pairReviewSHA256"] = pair.reviews.last!.sha256
                report["effectivePromptSHA256"] = pair.receipt.plan.promptSHA256
                report["lastKeyframeInputSHA256"] = pair.receipt.lastNormalized.sha256
                report["differentKeyframeImages"] = true
                report["persistentIdentityReferenceUsed"] = false
                report["identityLockVerified"] = false
            }
            if kind.usesIsolatedEngine,let engine = r.referenceEngine {
                try engine.validate(jobID:r.appJobID,workspace:r.workspace,workDirectory:proposal.workDirectory)
                if let policy = r.referenceTrialPolicy {
                    try policy.validate(jobID:r.appJobID,engine:engine,workspace:r.workspace)
                    report["trialPolicyReceiptSHA256"] = policy.receiptSHA256
                }
                guard let registryHash,try WorkspaceDigest.sha256(H3Files.safe(proposal.workDirectory + "/data.mdb")) == registryHash else {
                    throw StudioError.invalid("原生登记源发生变化，保留隔离对照，不能声称原数据库保持。")
                }
                let nativeLog = try H3Files.read(directory.appendingPathComponent("native.log"))
                let isReference = kind == .motionReferenceDetail
                report["engineRegistrationSHA256"] = engine.receiptSHA256
                report["originalTaskHelperSHA256"] = proposal.helperSHA256
                report["effectivePromptSHA256"] = H3ABConfigurationReader.digest(Data((isReference ? H3ReferenceEngine.prompt(proposal) : proposal.prompt).utf8))
                report["referenceMode"] = isReference ? "FL2VA-Ref2VA-like-zero-shot" : "FL2VA-single-first-frame-baseline"
                if isReference { report["referenceImageShortEdge"] = 768 }
                report["exactFirstFrameConditioning"] = !isReference
                report["identityLockVerified"] = false
                report["nativeLogSHA256"] = H3ABConfigurationReader.digest(nativeLog)
                report["nativeSessionDirectory"] = nativeDirectory.path
                report["sourceNativeRegistrySHA256"] = registryHash
                report["originalNativeRegistryUnchanged"] = true
                if let proof = r.referenceTrial {
                    report["referenceTrialID"] = proof.diagnosticID.uuidString
                    report["referenceTrialReportSHA256"] = proof.reportSHA256
                    report["referenceTrialObservationSHA256"] = proof.observationSHA256
                }
                try H3Fidelity.validateIsolatedMode(kind,report:report,log:String(decoding:nativeLog,as:UTF8.self),proposal:proposal)
            }
            if kind.isMotion {
                let clip = directory.appendingPathComponent("trial.mp4"),audit = try HistoricalClipAudit.capture(clip)
                guard audit.width == kind.width,audit.height == kind.height,audit.frames == kind.frames else { throw StudioError.invalid("短段对照实际帧数或尺寸不匹配。") }
                report["clipSHA256"] = try WorkspaceDigest.sha256(clip)
            }
            let reportURL = directory.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:reportURL,options:.withoutOverwriting)
            H3Supervisor.emit(.init(type:"fidelity_complete",reportPath:reportURL.path));return 0
        } catch {
            if let child,let scope,child.process.isRunning { H3Supervisor.stopOwned(child,scope:scope,mock:false) }
            else if let child,child.process.isRunning { child.process.terminate();child.process.waitUntilExit();child.drain() }
            if let request {
                let payload: [String:Any] = ["status":fidelityStop == 0 && request.ownerPresent() ? "failed_no_retry" : "cancelled","error":error.localizedDescription,"diagnosticID":request.id.uuidString]
                try? JSONSerialization.data(withJSONObject:payload,options:.prettyPrinted).write(to:URL(fileURLWithPath:request.directory + "/failure.json"),options:.withoutOverwriting)
            }
            H3Supervisor.emit(.init(type:"error",message:error.localizedDescription));return fidelityStop == 0 ? 1 : 130
        }
    }
}
