import Foundation
import AVFoundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

enum H3SourceFrames {
    typealias Progress = @Sendable (EngineEvent) async -> Void
    static func sourceHash(_ url: URL, expectedBytes: Int64, control: H3PreparationControl, progress: Progress) async throws -> String {
        _ = try H3Files.safe(url.path)
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])
        guard values.isRegularFile == true,Int64(values.fileSize ?? -1) == expectedBytes else { throw StudioError.invalid("源视频缺失或文件大小与提案不同。") }
        let handle = try FileHandle(forReadingFrom:url);defer { try? handle.close() }
        var digest = SHA256(),bytes: Int64 = 0,lastPublished: Int64 = -32_000_000
        while true {
            try control.check()
            guard let part = try handle.read(upToCount:1_048_576),!part.isEmpty else { break }
            bytes += Int64(part.count);guard bytes <= expectedBytes else { throw StudioError.invalid("源视频在读取期间发生变化。") }
            digest.update(data:part)
            if bytes - lastPublished >= 32_000_000 || bytes == expectedBytes {
                await progress(.init(type:"progress",stage:"检查源视频指纹",completed:Int(bytes),total:Int(expectedBytes),unit:"字节"))
                lastPublished = bytes
            }
        }
        let after = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard bytes == expectedBytes,after.fileSize == values.fileSize,after.contentModificationDate == values.contentModificationDate else {
            throw StudioError.invalid("源视频读取未完整完成或源文件已变化。")
        }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    struct Contained {
        var image: CGImage
        var scale: Double
        var translation: [Double]
        var padding: [Double]
    }
    /// Complete source→destination transform. All source pixels remain inside
    /// the 768×448 canvas; uncovered rows/columns are opaque black padding.
    static func contain(_ image: CGImage,canvasWidth: Int = 768,canvasHeight: Int = 448) throws -> Contained {
        let width = image.width,height = image.height
        guard [(768,448),(1536,896)].contains(where:{ $0.0 == canvasWidth && $0.1 == canvasHeight }),
              (1...8192).contains(width),(1...8192).contains(height),
              width*height <= 67_108_864,let color = CGColorSpace(name:CGColorSpace.sRGB) else { throw StudioError.invalid("源帧尺寸无法安全归一化。") }
        let scale = min(Double(canvasWidth)/Double(width),Double(canvasHeight)/Double(height))
        let tx = (Double(canvasWidth)-Double(width)*scale)/2,ty = (Double(canvasHeight)-Double(height)*scale)/2
        var transform = vImage_AffineTransform(a:Float(scale),b:0,c:0,d:Float(scale),tx:Float(tx),ty:Float(ty))
        var source = [UInt8](repeating:0,count:width*height*4)
        var output = [UInt8](repeating:0,count:canvasWidth*canvasHeight*4)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let error = try source.withUnsafeMutableBytes { input -> vImage_Error in
            guard let context = CGContext(data:input.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:info) else { throw StudioError.invalid("不能创建 CPU 源帧像素缓冲。") }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return output.withUnsafeMutableBytes { pixels in
                var from = vImage_Buffer(data:input.baseAddress,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width*4)
                var to = vImage_Buffer(data:pixels.baseAddress,height:vImagePixelCount(canvasHeight),width:vImagePixelCount(canvasWidth),rowBytes:canvasWidth*4)
                let background: [UInt8] = [0,0,0,255]
                return background.withUnsafeBufferPointer { bg in
                    vImageAffineWarp_ARGB8888(&from,&to,nil,&transform,bg.baseAddress!,vImage_Flags(kvImageHighQualityResampling | kvImageBackgroundColorFill))
                }
            }
        }
        guard error == kvImageNoError,let provider = CGDataProvider(data:Data(output) as CFData),
              let normalized = CGImage(width:canvasWidth,height:canvasHeight,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:canvasWidth*4,space:color,bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw StudioError.invalid("CPU 完整画面归一化失败。")
        }
        return .init(image:normalized,scale:Double(transform.a),translation:[Double(transform.tx),Double(transform.ty)],padding:[tx,ty,tx,ty])
    }
    static func save(_ image: CGImage, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath:url.path),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw StudioError.invalid("源帧预览目录已占用或无法写入。") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.invalid("源帧 PNG 写出失败。") }
    }
    static func technicalImage(_ path: String,hash: String,width: Int,height: Int) throws {
        let data = try H3Files.read(H3Files.safe(path),limit:50_331_648)
        guard H3ABConfigurationReader.digest(data) == hash,let source = CGImageSourceCreateWithData(data as CFData,nil),
              CGImageSourceGetStatus(source) == .statusComplete,CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == width,image.height == height else { throw StudioError.invalid("源帧图片的完整解码、尺寸或指纹检查失败。") }
    }
    static func exactPNG(source: URL,index: Int,output: URL,control: H3PreparationControl) throws -> CMTime {
        guard FileManager.default.isExecutableFile(atPath:AppIdentity.ffmpeg) else { throw StudioError.invalid("已核 FFmpeg 不可用，未安装新工具。") }
        let child = H3ChildProcess(),log = H3FrameDecodeLog()
        let arguments = ["-hide_banner","-loglevel","info","-nostdin","-n","-hwaccel","none","-threads","1","-filter_threads","1",
            "-copyts","-i",source.path,"-map","0:v:0","-vf","select=eq(n\\,\(index)),showinfo","-frames:v","1","-fps_mode","passthrough",
            "-c:v","png","-threads","1","-compression_level","1","-update","1",output.path]
        try child.start(executable:URL(fileURLWithPath:AppIdentity.ffmpeg),arguments:arguments,directory:output.deletingLastPathComponent()) { line,_ in log.append(line) }
        let scope = try OwnedProcessScope(process:child.process)
        defer { if child.process.isRunning { H3Supervisor.stopOwned(child,scope:scope,mock:true) } }
        let deadline = Date().addingTimeInterval(120)
        while child.process.isRunning {
            try control.check()
            guard Date() < deadline else { throw StudioError.invalid("CPU 精确提帧超时，保留已写出文件。") }
            Thread.sleep(forTimeInterval:0.02)
        }
        child.process.waitUntilExit();child.drain()
        guard child.process.terminationStatus == 0 else { throw StudioError.invalid("CPU 源帧解码失败：" + String(log.text().suffix(1200))) }
        let text = log.text()
        func captures(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern:pattern) else { return [] }
            return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { match in
                (1..<match.numberOfRanges).compactMap { Range(match.range(at:$0),in:text).map { String(text[$0]) } }
            }
        }
        let bases = captures(#"config in time_base:\s*(\d+)/(\d+)"#),frames = captures(#"\bn:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:"#)
        guard bases.count == 1,bases[0].count == 2,frames.count == 1,frames[0].count == 2,frames[0][0] == "0",
              let numerator = Int64(bases[0][0]),let denominator = Int32(bases[0][1]),denominator > 0,
              let pts = Int64(frames[0][1]),numerator > 0,numerator <= 1_000_000 else { throw StudioError.invalid("CPU 解码没有返回唯一实际帧与精确 PTS 回执。") }
        let actual = CMTime(value:pts*numerator,timescale:denominator)
        let receipt = output.deletingLastPathComponent().appendingPathComponent("cpu-frame-decoder.json")
        try JSONSerialization.data(withJSONObject:["schema":"jingsheng-App-CPU-exact-frame-decode-v1","command":arguments,
            "executable":AppIdentity.ffmpeg,"hardware_acceleration":"none","decoder_threads":1,"decoded_frame_index":index,
            "actual_pts_value":actual.value,"actual_pts_timescale":actual.timescale,"exit_code":0],options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.withoutOverwriting)
        return actual
    }
    static func prepare(_ proposal: H3FirstProposal,jobID: UUID,control: H3PreparationControl,validationRoot: URL? = nil,progress: Progress) async throws -> H3FirstInput {
        try control.check()
        let started = Date(),sourceURL = try H3Files.inside(proposal.sourceMediaPath,proposal.workDirectory)
        guard try await sourceHash(sourceURL,expectedBytes:proposal.sourceMediaBytes,control:control,progress:progress) == proposal.sourceMediaSHA256 else {
            throw StudioError.invalid("当前母片 SHA-256 与已核提案不同，未提取或生成。")
        }
        await progress(.init(type:"stage",stage:"核对源视频的精确帧位"))
        let asset = AVURLAsset(url:sourceURL)
        guard let track = asset.tracks(withMediaType:.video).first,
              Int(track.naturalSize.width) == proposal.sourceWidth,Int(track.naturalSize.height) == proposal.sourceHeight,
              abs(Double(track.nominalFrameRate)-Double(proposal.sourceFPS)) < 0.0001 else { throw StudioError.invalid("母片尺寸或帧率与提案不同。") }
        func timeText(_ value: CMTime) -> String { "\(value.value)/\(value.timescale)" }
        let mappings = track.segments.map { "sourceStart=\(timeText($0.timeMapping.source.start)),sourceDuration=\(timeText($0.timeMapping.source.duration)),targetStart=\(timeText($0.timeMapping.target.start)),targetDuration=\(timeText($0.timeMapping.target.duration)),empty=\($0.isEmpty)" }
        await progress(.init(type:"source_track_timeline",message:"trackStart=\(timeText(track.timeRange.start)),trackDuration=\(timeText(track.timeRange.duration)),naturalTimeScale=\(track.naturalTimeScale),nominalFrameRate=\(track.nominalFrameRate); " + mappings.joined(separator:"; ")))
        let reader = try AVAssetReader(asset:asset)
        // Read compressed samples only. Validate every presentation timestamp
        // and duration on the declared CFR grid without decoding the whole MV.
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:nil);output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.invalid("无法读取源视频帧位。") }
        reader.add(output);guard reader.startReading() else { throw StudioError.invalid("源视频帧位读取无法开始。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let target = CMTime(value:Int64(proposal.sourceFrameIndex),timescale:Int32(proposal.sourceFPS))
        let frameDuration = CMTime(value:1,timescale:Int32(proposal.sourceFPS))
        var indices = Set<Int>(),targetSeen = false,observed = 0
        while let sample = output.copyNextSampleBuffer() {
            try control.check()
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            // Zero-sample container boundary markers carry no video frame.
            if sampleCount == 0 { continue }
            guard sampleCount > 0,sampleCount <= proposal.sourceMediaFrames else { throw StudioError.invalid("源视频缓冲中的采样数量无效。") }
            for sampleIndex in 0..<sampleCount {
            try control.check()
            var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.invalid,decodeTimeStamp:.invalid)
            guard CMSampleBufferGetSampleTimingInfo(sample,at:sampleIndex,timingInfoOut:&timing) == noErr else { throw StudioError.invalid("无法读取源视频的逐帧实际时间。") }
            // Output timing applies the sample buffer's presentation offset.
            // Preserve per-sample timing inside aggregated buffers; DTS and
            // compressed-buffer order are never used as display-frame index.
            let offset = CMTimeSubtract(CMSampleBufferGetOutputPresentationTimeStamp(sample),CMSampleBufferGetPresentationTimeStamp(sample))
            let pts = CMTimeAdd(timing.presentationTimeStamp,offset),duration = timing.duration
            if observed < 12 || (proposal.sourceFrameIndex-6...proposal.sourceFrameIndex+6).contains(observed) || observed >= proposal.sourceMediaFrames-12 {
                await progress(.init(type:"source_sample_observed",message:"observed=\(observed), samples=\(sampleCount), bytes=\(CMSampleBufferGetSampleSize(sample,at:sampleIndex)), rawPTS=\(timeText(timing.presentationTimeStamp)), outputPTS=\(timeText(pts)), outputOffset=\(timeText(offset)), DTS=\(timing.decodeTimeStamp.value)/\(timing.decodeTimeStamp.timescale), duration=\(duration.value)/\(duration.timescale)"))
            }
            guard pts.isValid,!pts.isIndefinite,pts.timescale > 0,CMTimeCompare(duration,frameDuration) == 0 else { throw StudioError.invalid("源视频含可变或无效帧时长。") }
            let integer = CMTimeConvertScale(pts,timescale:Int32(proposal.sourceFPS),method:.roundTowardZero)
            guard CMTimeCompare(integer,pts) == 0,(0..<Int64(proposal.sourceMediaFrames)).contains(integer.value),
                  !indices.contains(Int(integer.value)) else {
                let detail = "observed=\(observed), bufferSamples=\(sampleCount), sampleIndex=\(sampleIndex), bytes=\(CMSampleBufferGetSampleSize(sample,at:sampleIndex)), PTS=\(pts.value)/\(pts.timescale), DTS=\(timing.decodeTimeStamp.value)/\(timing.decodeTimeStamp.timescale), duration=\(duration.value)/\(duration.timescale), presentationIndex=\(integer.value), duplicate=\(indices.contains(Int(integer.value)))"
                await progress(.init(type:"source_sample_rejected",message:detail))
                throw StudioError.invalid("源帧 PTS 网格存在缺失、重复或非整帧位：" + detail)
            }
            indices.insert(Int(integer.value))
            if CMTimeCompare(pts,target) == 0 { targetSeen = true }
            observed += 1
            if observed % 256 == 0 || observed == proposal.sourceMediaFrames {
                await progress(.init(type:"progress",stage:"核对精确源帧索引",completed:observed,total:proposal.sourceMediaFrames,unit:"帧位"))
            }
            }
        }
        guard reader.status == .completed,targetSeen,indices.count == proposal.sourceMediaFrames else { throw StudioError.invalid("源视频完整帧位核对失败，未使用近似定位。") }
        try control.check()
        await progress(.init(type:"stage",stage:"提取第 \(proposal.sourceFrameIndex) 帧 · 精确 PTS"))
        let inputRoot = validationRoot?.path ?? proposal.workDirectory + "/app-inputs"
        let revision = proposal.queueExecution?.actionRevision.map { "/revision-r\($0.number)/" + UUID().uuidString } ?? ""
        let directory = try H3Files.inside(inputRoot + "/App-source-frames/" + jobID.uuidString + revision,inputRoot)
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw StudioError.invalid("该 App 任务已有源帧目录，保留原产物且不覆盖。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original = directory.appendingPathComponent("source-frame-\(proposal.sourceFrameIndex).png")
        // Select the decoded presentation-frame index, with CPU-only decoder
        // and an independently verified exact PTS. No approximate seek.
        let actual = try exactPNG(source:sourceURL,index:proposal.sourceFrameIndex,output:original,control:control)
        let originalBytes = try H3Files.read(original,limit:50_331_648)
        guard CMTimeCompare(actual,target) == 0,let png = CGImageSourceCreateWithData(originalBytes as CFData,nil),
              let frame = CGImageSourceCreateImageAtIndex(png,0,nil),frame.width == proposal.sourceWidth,frame.height == proposal.sourceHeight else {
            throw StudioError.invalid("实际 CPU 解码帧 PTS、索引或尺寸不同，未接受近似帧。")
        }
        let originalHash = try WorkspaceDigest.sha256(original)
        await progress(.init(type:"prepared_original",path:original.path,message:originalHash))
        try control.check()
        await progress(.init(type:"stage",stage:"完整源帧归一化 · CPU Lanczos 与补边"))
        let contained = try contain(frame),normalized = directory.appendingPathComponent("A-normalized.png")
        try control.check();try save(contained.image,to:normalized)
        let normalizedHash = try WorkspaceDigest.sha256(normalized)
        await progress(.init(type:"prepared_normalized",path:normalized.path,message:normalizedHash))
        try technicalImage(original.path,hash:originalHash,width:frame.width,height:frame.height)
        try technicalImage(normalized.path,hash:normalizedHash,width:768,height:448)
        await progress(.init(type:"stage",stage:"核对提帧后源视频指纹"))
        guard try await sourceHash(sourceURL,expectedBytes:proposal.sourceMediaBytes,control:control,progress:{ _ in }) == proposal.sourceMediaSHA256 else {
            throw StudioError.invalid("母片在提帧期间发生变化；已保存预览，未进入 GPU。")
        }
        try control.check()
        let receiptURL = directory.appendingPathComponent("exact-frame-preparation.json")
        let receipt: [String:Any] = [
            "schema":"jingsheng-App-exact-source-frame-v1","app_job_id":jobID.uuidString,"proposal_sha256":proposal.sourceSHA256,
            "source_media_path":sourceURL.path,"source_media_sha256":proposal.sourceMediaSHA256,"exact_zero_based_index":proposal.sourceFrameIndex,
            "source_local_index":proposal.sourceLocalFrameIndex,"compressed_CFR_grid_frames_verified":observed,
            "actual_pts_value":actual.value,"actual_pts_timescale":actual.timescale,"requested_time_tolerance_before":0,"requested_time_tolerance_after":0,
            "original_path":original.path,"original_sha256":originalHash,"original_dimensions":[frame.width,frame.height],
            "normalized_path":normalized.path,"normalized_sha256":normalizedHash,"normalized_dimensions":[768,448],
            "source_crop_xyxy":[0,0,frame.width,frame.height],"source_to_destination_scale":contained.scale,
            "source_to_destination_translation":contained.translation,"padding_left_bottom_right_top":contained.padding,
            "algorithm":"CPU vImage high-quality Lanczos contain and opaque black padding","whole_image_preserved":true,"crop_executed":false,
            "technical_image_check":"complete_decode_dimensions_and_SHA256_pass","semantic_quality_assessed":false,
            "operator_approval_required":false,"H3_launched":false,"validation_only":validationRoot != nil,
            "production_input_eligible":validationRoot == nil,"started_at":ISO8601DateFormatter().string(from:started),
            "ended_at":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:receiptURL,options:.withoutOverwriting)
        return .init(originalPath:original.path,originalSHA256:originalHash,normalizedPath:normalized.path,normalizedSHA256:normalizedHash,
            extractionReceiptPath:receiptURL.path,extractionReceiptSHA256:try WorkspaceDigest.sha256(receiptURL),
            exactFrameIndex:proposal.sourceFrameIndex,actualPTSValue:actual.value,actualPTSTimescale:actual.timescale,
            originalWidth:frame.width,originalHeight:frame.height,scale:contained.scale,translation:contained.translation,padding:contained.padding)
    }
}

private final class H3FrameDecodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock();defer { lock.unlock() };if lines.count < 120 { lines.append(line) } }
    func text() -> String { lock.lock();defer { lock.unlock() };return lines.joined(separator:"\n") }
}
