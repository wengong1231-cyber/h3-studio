import Foundation
import ImageIO
import Darwin

enum H3FidelityKind: String, Codable, CaseIterable, Identifiable {
    case codecBaseline, codecDetail, motionDetail
    var id: String { rawValue }
    var width: Int { self == .codecBaseline ? 768 : 1536 }
    var height: Int { self == .codecBaseline ? 448 : 896 }
    var frames: Int { 22 }
    var title: String {
        switch self {
        case .codecBaseline: return "768 编解码对照"
        case .codecDetail: return "1536 编解码对照"
        case .motionDetail: return "1536 短段保真对照"
        }
    }
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
    var isActive: Bool { ["starting","running","cancelling"].contains(status) }
    var inputPath: String { directory + "/input.png" }
    var reportPath: String { directory + "/report.json" }
    var clipPath: String? { kind == .motionDetail && status == "completed" ? directory + "/trial.mp4" : nil }
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
    static func pipeline(kind: H3FidelityKind,proposal: H3FirstProposal,directory: String) throws -> Data {
        let template = try H3Files.readTemplateFallback()
        guard H3ABConfigurationReader.digest(template) == H3ABTaskBinding.templateSHA256 else { throw StudioError.invalid("保真管线模板指纹不同。") }
        var p = proposal
        p.profile.width = kind.width;p.profile.height = kind.height;p.profile.frames = kind.frames
        var graph = try JSONSerialization.jsonObject(with:H3FirstTaskBinding.pipeline(template:template,id:URL(fileURLWithPath:directory).lastPathComponent,
            proposal:p,first:directory + "/input.png",directory:directory)) as! [String:Any]
        let codecStages = Set(["model-select","load-A","vae-encode-A","vae-decode","save-detail-frames"])
        var result: [[String:Any]] = []
        for var stage in graph["stages"] as! [[String:Any]] {
            let id = stage["id"] as! String
            if kind != .motionDetail && !codecStages.contains(id) { continue }
            // The input has already been prepared at the requested size by the
            // App from the ORIGINAL. Never upscale a generated frame or run an
            // implicit crop/resample stage a second time.
            if id == "normalize-A" || id == "save-detail-source" { continue }
            var config = stage["config"] as! [String:Any]
            if id == "load-A" && kind != .motionDetail {
                config["url"] = Array(repeating:directory + "/input.png",count:codecInputFrames)
            }
            if id == "vae-encode-A" {
                if kind != .motionDetail {
                    result.append(["id":"stack-static-clip","type":"temporal-stack",
                        "iports":[["src":"load-A","oport":0]],
                        "config":["mode":"video","group_size":codecInputFrames,"overlap":0,"max_mb":192,"fps":24]])
                }
                stage["iports"] = [["src":kind == .motionDetail ? "load-A" : "stack-static-clip","oport":0],["src":"model-select","oport":0]]
            }
            if id == "vae-decode" && kind != .motionDetail { stage["iports"] = [["src":"vae-encode-A","oport":0],["src":"model-select","oport":0]] }
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
        if record.kind == .motionDetail {
            guard report["clipSHA256"] as? String == (try WorkspaceDigest.sha256(H3Files.inside(record.directory + "/trial.mp4",record.directory))) else { throw StudioError.invalid("对照视频已变化。") }
        }
        return bytes
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
            if kind == .codecBaseline {
                try H3SourceFrames.technicalImage(input.normalizedPath,hash:input.normalizedSHA256,width:768,height:448)
                try H3Files.read(H3Files.safe(input.normalizedPath),limit:50_331_648).write(to:directory.appendingPathComponent("input.png"),options:.withoutOverwriting)
            } else {
                guard let source = CGImageSourceCreateWithData(original as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw StudioError.invalid("原图无法解码。") }
                let normalized = try H3SourceFrames.contain(image,canvasWidth:kind.width,canvasHeight:kind.height)
                try H3SourceFrames.save(normalized.image,to:directory.appendingPathComponent("input.png"))
            }
            let inputHash = try WorkspaceDigest.sha256(directory.appendingPathComponent("input.png"))
            let graph = try H3Fidelity.pipeline(kind:kind,proposal:proposal,directory:r.directory)
            let pipeline = directory.appendingPathComponent("pipeline.vpipeline")
            try graph.write(to:pipeline,options:.withoutOverwriting)
            try FileManager.default.createDirectory(at:directory.appendingPathComponent("frames"),withIntermediateDirectories:false)
            let logger = try H3FidelityLog(directory.appendingPathComponent("native.log"));log = logger
            let native = H3ChildProcess();child = native
            let arguments = ["--memory-cap-mb","12288","--wired-pool-mb","8192","--launch",pipeline.path]
            H3Supervisor.emit(.init(type:"stage",stage:kind.title + " · 启动本机引擎"))
            try native.start(executable:URL(fileURLWithPath:proposal.helperPath),arguments:arguments,directory:URL(fileURLWithPath:proposal.workDirectory)) { line,stderr in
                logger.append(line)
                if let event = H3Progress.event(line) { H3Supervisor.emit(event) }
            }
            let owned = try OwnedProcessScope(process:native.process);scope = owned
            let started = Date();var next = Date.distantPast
            while native.process.isRunning {
                if fidelityStop != 0 || !r.ownerPresent() { throw H3PreprocessingCancelled() }
                if let error = logger.error { throw StudioError.invalid(error) }
                guard Date().timeIntervalSince(started) < 1800 else { throw StudioError.invalid("保真对照超时，保留记录，不自动重试。") }
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
                "recipeVersion":r.recipeVersion,"codecStaticInputFrames":kind == .motionDetail ? 0 : H3Fidelity.codecInputFrames,
                "sourceJobSHA256":r.binding.jobSHA256,"requestSHA256":H3ABConfigurationReader.digest(data),"pipelineSHA256":H3ABConfigurationReader.digest(graph),
                "appExecutableSHA256":r.appExecutableSHA256,"helperSHA256":proposal.helperSHA256,"librarySHA256":proposal.librarySHA256,
                "dimensions":[kind.width,kind.height],"frames":frames,"nativeExitCode":0,"promptSHA256":proposal.promptSHA256,"seed":proposal.seed,
                "steps":kind == .motionDetail ? proposal.profile.steps : 0,"motionGenerated":kind == .motionDetail,"videoAccepted":false,"continuationAuthorized":false,
                "inputFromOriginal":true,"upscaledGeneratedVideo":false,"command":arguments,"completedAt":ISO8601DateFormatter().string(from:Date())]
            if kind == .motionDetail {
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
