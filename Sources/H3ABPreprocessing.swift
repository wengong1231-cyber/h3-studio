import Foundation
import Accelerate
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct H3PreparedImage: Codable, Equatable {
    var role: String
    var path: String
    var sha256: String
    var writtenAt: Date
}
struct H3InputPreparation: Codable {
    var materialsStartedAt: Date
    var materialsEndedAt: Date
    var status = "waiting"
    var startedAt: Date?
    var endedAt: Date?
    var cancellationRequestedAt: Date?
    var images: [H3PreparedImage] = []
    var error: String?
    var receiptPath: String?
    var automaticValidationStatus: String?
    var automaticValidationStartedAt: Date?
    var automaticValidationEndedAt: Date?
    var automaticValidationReceiptPath: String?
}
final class H3PreparationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock();stopped = true;lock.unlock() }
    func check() throws { lock.lock();let value = stopped;lock.unlock();if value { throw H3PreprocessingCancelled() } }
}
struct H3PreprocessingCancelled: LocalizedError {
    var errorDescription: String? { "App 图片预处理已取消，保留已完成图片；未进入 GPU。" }
}

enum H3ABPreprocessor {
    struct Normalized {
        let image: CGImage
        let sourceCrop: [Double]
        let scale: Double
        let translation: [Double]
    }
    static func normalize(_ image: CGImage) throws -> Normalized {
        let width = image.width,height = image.height
        guard (1...8192).contains(width),(1...8192).contains(height),let colorSpace = CGColorSpace(name:CGColorSpace.sRGB) else { throw StudioError.invalid("S41 原图尺寸或颜色空间无效。") }
        let scale = max(768.0 / Double(width),448.0 / Double(height))
        let tx = -(Double(width)*scale - 768)/2,ty = -(Double(height)*scale - 448)/2
        // SDK Geometry.h defines this transform as source→destination, with
        // the same bottom-left coordinates as CoreGraphics. vImage is CPU only.
        var transform = vImage_AffineTransform(a:Float(scale),b:0,c:0,d:Float(scale),tx:Float(tx),ty:Float(ty))
        var sourcePixels = [UInt8](repeating:0,count:width*height*4)
        var outputPixels = [UInt8](repeating:0,count:768*448*4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let result = try sourcePixels.withUnsafeMutableBytes { input -> vImage_Error in
            guard let context = CGContext(data:input.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,bitmapInfo:bitmapInfo) else { throw StudioError.invalid("不能用 CPU 解码 S41 参考图。") }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return outputPixels.withUnsafeMutableBytes { output in
                var source = vImage_Buffer(data:input.baseAddress,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width*4)
                var destination = vImage_Buffer(data:output.baseAddress,height:448,width:768,rowBytes:768*4)
                let background: [UInt8] = [0,0,0,0]
                return background.withUnsafeBufferPointer { color in
                    vImageAffineWarp_ARGB8888(&source,&destination,nil,&transform,color.baseAddress!,vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend))
                }
            }
        }
        guard result == kvImageNoError,let provider = CGDataProvider(data:Data(outputPixels) as CFData),
              let output = CGImage(width:768,height:448,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:768*4,space:colorSpace,bitmapInfo:CGBitmapInfo(rawValue:bitmapInfo),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw StudioError.invalid("S41 CPU Lanczos 归一化失败，vImage 错误 \(result)。") }
        let actualScale = Double(transform.a),actualX = Double(transform.tx),actualY = Double(transform.ty)
        return .init(image:output,sourceCrop:[-actualX/actualScale,-actualY/actualScale,(768-actualX)/actualScale,(448-actualY)/actualScale],scale:actualScale,translation:[actualX,actualY])
    }
    // This is an App task step, using a software renderer. It cannot initialize
    // a diffusion model, download, launch Vpipe or submit a GPU pipeline.
    static func prepare(_ configuration: H3ABConfiguration,jobID: UUID,descriptorData: Data,mock: Bool,control: H3PreparationControl,didPrepare: @Sendable (H3PreparedImage) async -> Void) async throws -> H3ABConfigurationRead {
        try control.check()
        guard let a = configuration.first.originalPath,let aHash = configuration.first.originalSHA256,
              let b = configuration.last.originalPath,let bHash = configuration.last.originalSHA256 else { throw StudioError.invalid("S41 原图与指纹未齐，未归一化。") }
        let fm = FileManager.default
        let directory = try H3Files.inside(configuration.workDirectory + "/app-inputs/App-preprocessed/" + jobID.uuidString,configuration.workDirectory + "/app-inputs")
        guard !fm.fileExists(atPath:directory.path) else { throw StudioError.invalid("这条 App 任务已准备过输入；保留旧文件，请核对原任务。") }
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let started = Date()
        var root = try JSONSerialization.jsonObject(with:descriptorData) as! [String:Any]
        var inputs = root["inputs"] as! [String:Any]
        var receipts: [[String:Any]] = []
        for (name,path,hash) in [("A",a,aHash),("B",b,bHash)] {
            try control.check()
            let source = try H3ABConfigurationReader.imagePath(path,workDirectory:configuration.workDirectory,mock:mock),bytes = try H3Files.read(source,limit:50_331_648)
            guard H3ABConfigurationReader.digest(bytes) == hash,let imageSource = CGImageSourceCreateWithData(bytes as CFData,nil),let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw StudioError.invalid(name + " 原图变化或不能解码，未归一化。") }
            let normalized = try normalize(image)
            try control.check()
            let target = directory.appendingPathComponent(name + "-normalized.png")
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL,UTType.png.identifier as CFString,1,nil) else { throw StudioError.invalid("不能保存 S41 归一预览。") }
            CGImageDestinationAddImage(destination,normalized.image,nil)
            guard CGImageDestinationFinalize(destination) else { throw StudioError.invalid("S41 归一预览保存失败。") }
            let outputHash = try WorkspaceDigest.sha256(target)
            await didPrepare(.init(role:name,path:target.path,sha256:outputHash,writtenAt:Date()))
            var input = inputs[name] as! [String:Any]
            input["normalized_path"] = target.path;input["normalized_sha256"] = outputHash;input["normalized_visual_review_passed"] = false;input["normalized_exists"] = true
            inputs[name] = input
            receipts.append(["input":name,"original_path":path,"original_sha256":hash,"original_dimensions":[image.width,image.height],"normalized_path":target.path,"normalized_sha256":outputHash,"normalized_dimensions":[768,448],"source_crop_xyxy":normalized.sourceCrop,"algorithm":"CPU vImageAffineWarp_ARGB8888 high-quality Lanczos center crop","source_to_destination_scale":normalized.scale,"source_to_destination_translation":normalized.translation,"letterboxing":false,"color_space":"sRGB","software_renderer":true,"semantic_quality":"not_automatically_evaluated"])
            guard try WorkspaceDigest.sha256(source) == hash else { throw StudioError.invalid("S41 原图在归一化期间改变。") }
        }
        try control.check()
        let receipt = directory.appendingPathComponent("preprocessing-receipt.json")
        let record: [String:Any] = ["schema":"jingsheng-App-input-preprocessing-v1","app_job_id":jobID.uuidString,"app_bundle_id":AppIdentity.bundleID,"started_at":ISO8601DateFormatter().string(from:started),"ended_at":ISO8601DateFormatter().string(from:Date()),"gpu_launched":false,"native_helper_launched":false,"images_prepared":2,"software_renderer":true,"operator_approval_required":false,"semantic_quality":"not_automatically_evaluated","frames":receipts]
        try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:receipt,options:.withoutOverwriting)
        root["inputs"] = inputs;root["App_preprocessing_receipt"] = receipt.path;root["App_original_proposal_sha256"] = configuration.originalProposalSHA256 ?? configuration.sourceSHA256
        let updated = try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys,.prettyPrinted])
        return try H3ABConfigurationReader.parse(updated,sourcePath:configuration.sourcePath,workDirectory:configuration.workDirectory,mock:mock)
    }
}

extension TaskStore {
    func canNormalizeS41(_ id: UUID) -> Bool {
        guard let job = state.jobs.first(where:{ $0.id == id }),let configuration = job.h3ABConfiguration else { return false }
        return canUseS41Resources(id) && job.status.isPending && job.attempts.isEmpty && job.h3Binding == nil && job.h3InputPreparation?.status != "failed" && configuration.first.originalPath != nil && configuration.first.originalSHA256 != nil && configuration.last.originalPath != nil && configuration.last.originalSHA256 != nil && configuration.launchAuthorized && configuration.promptReviewed && configuration.first.normalizedSHA256 == nil && configuration.last.normalizedSHA256 == nil
    }
    func prepareS41Inputs(_ id: UUID) async {
        guard canNormalizeS41(id),let index = state.jobs.firstIndex(where:{ $0.id == id }),let configuration = state.jobs[index].h3ABConfiguration,let snapshot = configuration.snapshotPath else { return }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let control = H3PreparationControl()
        abPreparationID = id;abPreparationControl = control
        defer {
            if let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].h3InputPreparation?.status == "cancelled" {
                state.jobs[current].h3InputPreparation?.endedAt = Date();state.jobs[current].progress = nil;persist()
            }
            abPreparationID = nil;abPreparationControl = nil
        }
        let now = Date()
        if state.jobs[index].h3InputPreparation == nil { state.jobs[index].h3InputPreparation = .init(materialsStartedAt:now,materialsEndedAt:now) }
        state.jobs[index].h3InputPreparation?.status = "running";state.jobs[index].h3InputPreparation?.startedAt = now;state.jobs[index].h3InputPreparation?.endedAt = nil
        state.jobs[index].h3InputPreparation?.error = nil;state.jobs[index].error = nil
        state.jobs[index].stage = "App 输入归一化 · CPU 软件 Lanczos";state.jobs[index].progress = nil
        if state.jobs[index].executionActivity == nil { state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:now) }
        else { state.jobs[index].executionActivity?.milestone(state.jobs[index].stage,at:now,phase:.preparing) }
        state.jobs[index].logTail.append("App 已登记输入预处理；只用 CPU 软件渲染准备 768×448 A/B，不运行 H3，不下载模型。")
        persist();guard storageFault == nil else { return }
        let mock = h3Runtime.mode == .mock
        do {
            let prepared = try await Task.detached(priority:.utility) {
                let data = try H3Files.read(URL(fileURLWithPath:snapshot),limit:1_048_576)
                guard H3ABConfigurationReader.digest(data) == configuration.sourceSHA256 else { throw StudioError.invalid("S41 配置快照变化，未处理。") }
                return try await H3ABPreprocessor.prepare(configuration,jobID:id,descriptorData:data,mock:mock,control:control) { [weak self] image in
                    await self?.recordPreparedS41Image(image,jobID:id)
                }
            }.value
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending,state.jobs[current].h3ABConfiguration == configuration else { return }
            try saveS41Configuration(prepared,index:current)
            state.jobs[current].stage = "A/B 图片处理完成 · 自动输入检查通过"
            state.jobs[current].executionActivity?.milestone(state.jobs[current].stage,at:Date(),phase:.preparing)
            state.jobs[current].h3InputPreparation?.status = "completed";state.jobs[current].h3InputPreparation?.endedAt = Date();state.jobs[current].h3InputPreparation?.receiptPath = prepared.configuration.preprocessingReceiptPath
            state.jobs[current].logTail.append("两张归一图实际写出；完整解码、768×448 尺寸与 SHA-256 自动检查通过，无需人工放行。")
            notice = "A/B 已处理并自动校验；预览可随时查看。"
            persist()
        } catch {
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending,state.jobs[current].h3ABConfiguration == configuration else { return }
            notice = error.localizedDescription;state.jobs[current].stage = "输入归一化未完成 · 未进入 GPU";state.jobs[current].error = error.localizedDescription
            state.jobs[current].h3InputPreparation?.status = "failed";state.jobs[current].h3InputPreparation?.endedAt = Date();state.jobs[current].h3InputPreparation?.error = error.localizedDescription;persist()
        }
    }
    func recordPreparedS41Image(_ image: H3PreparedImage,jobID: UUID) {
        guard let index = state.jobs.firstIndex(where:{ $0.id == jobID }),state.jobs[index].h3InputPreparation != nil else { return }
        if state.jobs[index].h3InputPreparation?.images.contains(where:{ $0.role == image.role }) == false { state.jobs[index].h3InputPreparation?.images.append(image) }
        state.jobs[index].logTail.append("\(image.writtenAt.formatted(date:.omitted,time:.standard)) · \(image.role) 768×448 预览实际写出，SHA-256 \(image.sha256)。")
        if state.jobs[index].h3InputPreparation?.status == "running",state.jobs[index].status.isPending {
            let count = state.jobs[index].h3InputPreparation?.images.count ?? 0
            state.jobs[index].progress = .init(completed:count,total:2,unit:"张参考图")
            state.jobs[index].executionActivity?.observe(.init(type:"progress",stage:state.jobs[index].stage,completed:count,total:2,unit:"张参考图"),at:image.writtenAt)
        }
        state.jobs[index].updatedAt = Date();persist()
    }
}
