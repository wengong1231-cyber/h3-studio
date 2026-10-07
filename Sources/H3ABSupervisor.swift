import Foundation
import AVFoundation
import ImageIO
import Darwin

private var abStopSignal: Int32 = 0

private final class ABNativeLog {
    let lock = NSLock()
    var handle: FileHandle
    var latestProgress: String?
    var failure: String?
    init(_ url: URL) throws {
        try Data().write(to:url,options:.withoutOverwriting)
        handle = try FileHandle(forWritingTo:url)
    }
    func append(_ line: String,stderr: Bool) {
        lock.lock();defer { lock.unlock() }
        do { try handle.write(contentsOf:Data((line + "\n").utf8)) }
        catch { failure = "原生日志无法保存：" + error.localizedDescription }
        if line.contains("[PROGRESS]") { latestProgress = line }
        if line.range(of:#"\[ERROR\]|out of memory|bad_alloc|resource exhausted|segmentation fault|Permission denied|Operation not permitted|unknown stage"#,options:[.regularExpression,.caseInsensitive]) != nil { failure = String(line.prefix(1800)) }
        H3Supervisor.emit(EngineEvent(type:"log",message:(stderr ? "native stderr: " : "native: ") + line))
        if let event = H3Progress.event(line) { H3Supervisor.emit(event) }
    }
    func values() -> (String?,String?) { lock.lock();defer { lock.unlock() };return (latestProgress,failure) }
    func close() { lock.lock();defer { lock.unlock() };try? handle.close() }
}

enum H3ABSupervisor {
    private static func utc() -> String {
        let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.string(from:Date())
    }
    static func run(requestURL: URL) -> Int32 {
        signal(SIGTERM) { _ in abStopSignal = 1 };signal(SIGINT) { _ in abStopSignal = 1 };signal(SIGPIPE,SIG_IGN)
        var child: H3ChildProcess?,scope: OwnedProcessScope?,request: H3WorkerRequest?,job: H3SingleJob?,nativeLog: ABNativeLog?
        var generatorLock: URL?,generatorLockData: Data?
        var state: [String:Any] = [:]
        let fm = FileManager.default
        defer {
            nativeLog?.close()
            if let generatorLock,let generatorLockData,(try? H3Files.read(generatorLock,limit:4096)) == generatorLockData { try? fm.removeItem(at:generatorLock) }
        }
        do {
            let loaded = try JSONDecoder().decode(H3WorkerRequest.self,from:H3Files.read(requestURL));request = loaded
            guard loaded.version == 1,H3Supervisor.ownerPresent(loaded),
                  loaded.binding.appTaskID == loaded.appJobID,loaded.binding.appTaskWorkspace == loaded.workspace else { throw StudioError.invalid("App 镜头任务、工作区或所有权不匹配。") }
            let singleFirst = loaded.binding.appFirstTask?.proposal
            let taskLabel = singleFirst?.shortID ?? "S41"
            let nativeFrames = loaded.binding.profile.frames
            let editorialFrames = singleFirst?.targetFrames ?? 72
            _ = try H3Files.inside(loaded.attemptDirectory,loaded.workspace + "/candidates")
            let receiptURL = try H3Files.inside(loaded.workspace + "/h3-dispatch/" + loaded.binding.jobSHA256 + ".json",loaded.workspace + "/h3-dispatch")
            let receipt = try JSONDecoder().decode(H3DispatchReceipt.self,from:H3Files.read(receiptURL))
            guard receipt.appJobID == loaded.appJobID,receipt.jobSHA256 == loaded.binding.jobSHA256,receipt.sessionID == loaded.sessionID else { throw StudioError.invalid("\(taskLabel) 投递回执与 App 任务不一致。") }
            let current = try loaded.binding.revalidate();job = current
            try loaded.binding.requireExecutionAuthorization()
            let mock = loaded.binding.runtime.mode == .mock
            guard !ProcessInfo.processInfo.environment.keys.contains(where:{ $0.hasPrefix("VPIPE_H3") || $0.hasPrefix("VPIPE_MINIMAX_H3") }) else { throw StudioError.invalid("存在契约外 H3 环境覆盖，未执行。") }
            if !mock {
                let preparation = ModelStatusReader.read(URL(fileURLWithPath:current.work_dir))
                guard case .success(let verified) = preparation,verified.verification.quantization.state == .verified,verified.verification.runtime.state == .verified else { throw StudioError.invalid("当前模型注册或已核运行时未确认，未执行 S41。") }
            }
            let capacity = try URL(fileURLWithPath:current.work_dir).resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard Int64(capacity) >= current.minimum_free_bytes else { throw StudioError.invalid("磁盘余量不足 S41 储备。") }
            let lockURL = try H3Files.inside(current.work_dir + "/active-single-shot.lock",current.work_dir)
            let lockData = try JSONSerialization.data(withJSONObject:["controller_pid":getpid(),"app_job_id":loaded.appJobID.uuidString,"native_job_id":current.job_id,"session":loaded.sessionID.uuidString,"job_sha256":loaded.binding.jobSHA256,"started_at":utc()],options:.sortedKeys)
            // The original single-shot runner uses the same O_EXCL lease. A
            // pre-existing lease is never removed or treated as our process.
            let fd = open(lockURL.path,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw StudioError.invalid("已有单镜执行锁；未启动第二个 GPU，也未接管旧 PID。") }
            generatorLock = lockURL;generatorLockData = lockData
            let written = lockData.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,$0.count) };let flushed = fsync(fd);close(fd)
            guard written == lockData.count,flushed == 0 else { throw StudioError.invalid("单镜资源锁无法完整保存。") }
            let claimURL = try H3Files.inside(current.output_dir + "/attempt-once.json",current.output_dir)
            try JSONSerialization.data(withJSONObject:["app_job_id":loaded.appJobID.uuidString,"native_job_id":current.job_id,"job_sha256":loaded.binding.jobSHA256,"controller_pid":getpid(),"claimed_at":utc(),"app_created_executed_logged":true,"automatic_retry":false],options:.sortedKeys).write(to:claimURL,options:.withoutOverwriting)
            let logURL = try H3Files.inside(current.output_dir + "/record/native-run.log",current.output_dir)
            let log = try ABNativeLog(logURL);nativeLog = log
            let native = H3ChildProcess();child = native
            let executable = mock ? URL(fileURLWithPath:loaded.binding.runtime.executable) : URL(fileURLWithPath:current.helper_path)
            let args = mock ? ["--h3-ab-mock-worker",requestURL.path] : ["--memory-cap-mb",String(current.profile.memory_cap_mb),"--wired-pool-mb",String(current.profile.wired_pool_mb),"--launch",current.pipeline_path]
            let started = Date(),startedAt = utc()
            state = ["status":"starting","job_id":current.job_id,"shot_number":current.shot_number,"app_job_id":loaded.appJobID.uuidString,"app_launched":true,"controller_pid":getpid(),"output_dir":current.output_dir,"clip_path":current.clip_path,"started_at":startedAt,"selected_for_production":false,"automatic_retry":false,"attempt_count":1,"generation_started":false,"simulated":mock,"command":args,"cwd":current.work_dir,"editorial_frames":editorialFrames,"native_frames":nativeFrames,"native_fps":current.profile.fps,"native73_runtime_observed":false,"native90_runtime_observed":false]
            if let singleFirst { state["selected_raw_half_open"] = [singleFirst.selectedRawStart,singleFirst.selectedRawEnd];state["first_anchor_port"] = 5;state["last_anchor_connected"] = false }
            else { state["B_anchor_index"] = 72;state["B_anchor_pts_seconds"] = 3.0 }
            let statusURL = URL(fileURLWithPath:current.output_dir + "/status.json")
            func persist() throws {
                state["updated_at"] = utc();state["elapsed_seconds"] = Date().timeIntervalSince(started)
                if let progress = log.values().0 { state["latest_progress"] = progress }
                try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys,.prettyPrinted]).write(to:statusURL,options:.atomic)
            }
            try persist()
            H3Supervisor.emit(EngineEvent(type:"stage",stage:mock ? "\(taskLabel) CPU 模拟启动" : "\(taskLabel) 原生启动 · \(nativeFrames) 帧",message:"App 已保存独立任务、实际输入与管线指纹；只运行这一条。"))
            guard abStopSignal == 0,H3Supervisor.ownerPresent(loaded) else { return 130 }
            native.process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL":"C"]) { _,new in new }
            try native.start(executable:executable,arguments:args,directory:URL(fileURLWithPath:current.work_dir)) { line,stderr in log.append(line,stderr:stderr) }
            let ownership = try OwnedProcessScope(process:native.process);scope = ownership
            state["vpipe_pid"] = native.process.processIdentifier;state["status"] = "generating";state["generation_started"] = true;try persist()
            H3Supervisor.emit(EngineEvent(type:"native_started"))
            var nextOwned = Date.distantPast,nextPersist = Date.distantPast,nextResource = Date.distantPast,highRSS = 0
            func cancelled() -> Bool { abStopSignal != 0 || !H3Supervisor.ownerPresent(loaded) }
            while native.process.isRunning {
                if cancelled() {
                    state["status"] = "stopping";try? persist()
                    H3Supervisor.stopOwned(native,scope:ownership,mock:mock)
                    state["status"] = "cancelled";state["ended_at"] = utc();state["native_exit_code"] = native.process.terminationStatus;state["vpipe_pid"] = NSNull();try? persist()
                    if fm.fileExists(atPath:current.clip_path) { H3Supervisor.emit(EngineEvent(type:"partial_output",path:current.clip_path)) }
                    return 130
                }
                if let failure = log.values().1 { throw StudioError.invalid("原生执行错误：" + failure) }
                guard Date().timeIntervalSince(started) < current.max_wall_seconds else { throw StudioError.invalid("\(taskLabel) 达到单镜耗时上限；不自动重试。") }
                if Date() >= nextOwned {
                    ownership.refresh();H3Supervisor.emit(EngineEvent(type:"owned",ownedProcesses:ownership.living));nextOwned = Date().addingTimeInterval(mock ? 0.2 : 10)
                }
                if Date() >= nextResource && !mock {
                    var info = proc_taskinfo()
                    if proc_pidinfo(native.process.processIdentifier,PROC_PIDTASKINFO,0,&info,Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size {
                        let rss = info.pti_resident_size
                        state["peak_rss_bytes"] = max((state["peak_rss_bytes"] as? UInt64) ?? 0,rss)
                        highRSS = rss > 22 * 1_073_741_824 ? highRSS + 1 : 0
                        guard highRSS < 3 else { throw StudioError.invalid("原生进程连续三次超过 22 GiB 驻留内存，保护本机资源。") }
                    }
                    let available = try URL(fileURLWithPath:current.work_dir).resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                    guard Int64(available) >= 15 * 1_073_741_824 else { throw StudioError.invalid("磁盘余量低于 15 GiB，停止自有 S41 进程。") }
                    nextResource = Date().addingTimeInterval(10)
                }
                if Date() >= nextPersist { try persist();nextPersist = Date().addingTimeInterval(mock ? 0.1 : 2) }
                Thread.sleep(forTimeInterval:0.05)
            }
            native.process.waitUntilExit();native.drain();log.close();nativeLog = nil
            state["vpipe_pid"] = NSNull();state["native_exit_code"] = native.process.terminationStatus;state["native_completed_at"] = utc();state["ended_at"] = utc()
            state["status"] = native.process.terminationStatus == 0 ? "native_completed_pending_validation" : "failed_no_auto_retry";try persist()
            guard !cancelled() else { return 130 }
            guard native.process.terminationStatus == 0,log.values().1 == nil else { throw StudioError.invalid("\(taskLabel) 原生退出 \(native.process.terminationStatus)；候选保留，不自动重试。") }
            guard fm.fileExists(atPath:current.clip_path) else { throw StudioError.invalid("\(taskLabel) 原生 exit 0，但候选视频未写出。") }
            H3Supervisor.emit(EngineEvent(type:"partial_output",path:current.clip_path))
            H3Supervisor.emit(EngineEvent(type:"validation_started"))
            H3Supervisor.emit(EngineEvent(type:"stage",stage:"\(taskLabel) 严格技术质检 · 期望 \(nativeFrames) 帧"))
            var currentValidation: H3ChildProcess?,validationScope: OwnedProcessScope?
            defer {
                if let currentValidation,let validationScope,currentValidation.process.isRunning { H3Supervisor.stopOwned(currentValidation,scope:validationScope,mock:mock) }
            }
            func decode(_ args: [String],name: String) throws -> Int {
                guard fm.isExecutableFile(atPath:loaded.ffmpeg) else { throw StudioError.invalid("没有已核 FFmpeg；未安装或替换工具。") }
                _ = try H3Files.safe(loaded.ffmpeg)
                let decoder = H3ChildProcess();currentValidation = decoder
                let collect = ABDecodeCount()
                try decoder.start(executable:URL(fileURLWithPath:loaded.ffmpeg),arguments:args,directory:URL(fileURLWithPath:current.output_dir)) { line,stderr in
                    collect.append(line,stderr:stderr)
                    H3Supervisor.emit(EngineEvent(type:"log",message:name + ": " + line))
                }
                let owned = try OwnedProcessScope(process:decoder.process);validationScope = owned;child = decoder;scope = owned
                let deadline = Date().addingTimeInterval(120)
                while decoder.process.isRunning {
                    if cancelled() { H3Supervisor.stopOwned(decoder,scope:owned,mock:mock);throw ABValidationCancelled() }
                    guard Date() < deadline else { H3Supervisor.stopOwned(decoder,scope:owned,mock:mock);throw StudioError.invalid(name + " 超时，候选保留。") }
                    owned.refresh();Thread.sleep(forTimeInterval:0.05)
                }
                decoder.process.waitUntilExit();decoder.drain()
                let result = collect.result()
                guard decoder.process.terminationStatus == 0,result.1.isEmpty else { throw StudioError.invalid(name + " 严格解码失败：" + String(result.1.prefix(1000))) }
                return result.0
            }
            let actualVideo = try HistoricalClipAudit.capture(try H3Files.inside(current.clip_path,current.output_dir))
            guard !AVURLAsset(url:URL(fileURLWithPath:current.clip_path)).tracks(withMediaType:.audio).isEmpty else { throw StudioError.invalid("\(taskLabel) MP4 缺少原生音轨；未接受输出。") }
            guard actualVideo.frames == current.profile.frames,actualVideo.width == current.profile.width,actualVideo.height == current.profile.height,
                  abs(actualVideo.fps - Double(current.profile.fps)) < 0.0001,abs(actualVideo.duration - Double(current.profile.frames) / Double(current.profile.fps)) < 0.0001 else { throw StudioError.invalid("\(taskLabel) 实际 MP4 的尺寸、帧数、帧率或视频时长不符；未接受输出。") }
            let common = ["-hide_banner","-loglevel","error","-nostdin","-xerror","-err_detect","explode","-threads","1","-filter_threads","1"]
            let decoded = try decode(common + ["-i",current.clip_path,"-map","0:v:0","-map","0:a?","-fps_mode","passthrough","-progress","pipe:1","-nostats","-f","null","-"],name:"MP4 全部音视频")
            guard decoded == current.profile.frames else { throw StudioError.invalid("\(taskLabel) 完整 A/V 解码帧数不是 \(current.profile.frames)。") }
            let raw = try H3Files.inside(current.output_dir + "/record/lossless-frames",current.output_dir)
            let names = try fm.contentsOfDirectory(atPath:raw.path).filter { $0.lowercased().hasSuffix(".png") }.sorted()
            guard names == (0..<current.profile.frames).map({ String(format:"frame-%04d.png",$0) }) else { throw StudioError.invalid("\(taskLabel) 无损帧序列缺失、多余或顺序不正确。") }
            var frameReceipts: [[String:Any]] = []
            for (index,name) in names.enumerated() {
                if cancelled() { throw ABValidationCancelled() }
                let file = try H3Files.inside(raw.path + "/" + name,raw.path),data = try H3Files.read(file,limit:50_331_648)
                guard let imageSource = CGImageSourceCreateWithData(data as CFData,nil),let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil),
                      image.width == current.profile.width,image.height == current.profile.height else { throw StudioError.invalid("\(taskLabel) 第 \(index) 张原生无损帧尺寸或解码不正确。") }
                frameReceipts.append(["source_index":index,"sha256":H3ABConfigurationReader.digest(data),"file":name])
                H3Supervisor.emit(EngineEvent(type:"progress",stage:"检查原生无损帧",completed:index+1,total:names.count,unit:"帧质检"))
            }
            H3Supervisor.emit(EngineEvent(type:"stage",stage:"完整解码原生无损序列"))
            let rawDecoded = try decode(common + ["-framerate",String(current.profile.fps),"-start_number","0","-i",raw.path + "/frame-%04d.png","-map","0:v:0","-fps_mode","passthrough","-progress","pipe:1","-nostats","-f","null","-"],name:"原生 PNG 序列")
            guard rawDecoded == current.profile.frames else { throw StudioError.invalid("\(taskLabel) 原生无损序列严格解码帧数不符。") }
            for (path,hash) in current.frozen {
                if cancelled() { throw ABValidationCancelled() }
                guard try WorkspaceDigest.sha256(H3Files.safe(path)) == hash else { throw StudioError.invalid("\(taskLabel) 冻结输入在执行期间变化。") }
            }
            let clipHash = try WorkspaceDigest.sha256(URL(fileURLWithPath:current.clip_path))
            var report: [String:Any] = ["schema":singleFirst == nil ? "jingsheng-App-S41-native-technical-v2" : "jingsheng-App-first-frame-native-technical-v1","status":"technical_pass","job_id":current.job_id,"app_job_id":loaded.appJobID.uuidString,"shot_number":current.shot_number,"clip_path":current.clip_path,"clip_sha256":clipHash,"native_exit_code":0,"decoded_video_frames":decoded,"expected_native_frames":nativeFrames,"native_lossless_frames":rawDecoded,"dimensions":[current.profile.width,current.profile.height],"fps":current.profile.fps,"video_duration_seconds":actualVideo.duration,"strict_full_av_decode":"pass","strict_lossless_decode":"pass","original_frozen_files_unchanged":true,"selected_for_production":false,"visual_review":"not_automatically_evaluated","operator_approval_required":false,"semantic_quality_assessed":false,"simulated":mock,"native73_runtime_observed":!mock && nativeFrames == 73,"native90_runtime_observed":!mock && nativeFrames == 90,"editorial_target_frames":editorialFrames,"editorial_target_seconds":Double(editorialFrames)/Double(current.profile.fps),"adaptation_executed":false,"lossless_frame_receipts":frameReceipts,"completed_at":utc()]
            if let singleFirst {
                report["selected_raw_half_open"] = [singleFirst.selectedRawStart,singleFirst.selectedRawEnd]
                report["first_anchor_port"] = 5;report["last_anchor_connected"] = false
                report["source_frame_index"] = singleFirst.sourceFrameIndex
                report["input_pixel_review_sha_bound"] = true
                report["continuation_endpoint_raw_index"] = singleFirst.selectedRawEnd - 1
                report["continuation_endpoint_sha256"] = frameReceipts[singleFirst.selectedRawEnd - 1]["sha256"]
                report["selected_window_pixel_review"] = "not_yet_evaluated"
                report["continuation_launched"] = false
            } else { report["B_anchor_index"] = 72;report["B_anchor_pts_seconds"] = 3.0 }
            let reportURL = URL(fileURLWithPath:current.output_dir + "/technical-validation.json")
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:reportURL,options:.withoutOverwriting)
            guard !cancelled() else { throw ABValidationCancelled() }
            state["status"] = "technical_pass";state["native73_runtime_observed"] = !mock && nativeFrames == 73;state["native90_runtime_observed"] = !mock && nativeFrames == 90;state["original_frozen_files_unchanged"] = true;state["technical_validation"] = reportURL.path;try persist()
            H3Supervisor.emit(EngineEvent(type:"technical_pass",stage:mock ? "\(taskLabel) CPU 协议通过 · 非真实 H3" : "自动技术检查通过 · 候选已保存",path:current.clip_path,reportPath:reportURL.path,simulated:mock))
            return 0
        } catch {
            let mock = request?.binding.runtime.mode == .mock
            if let child,let scope,child.process.isRunning { H3Supervisor.stopOwned(child,scope:scope,mock:mock) }
            else if let child,child.process.isRunning { child.process.terminate();child.process.waitUntilExit();child.drain() }
            nativeLog?.close();nativeLog = nil
            let cancelled = error is ABValidationCancelled || abStopSignal != 0 || request.map({ !H3Supervisor.ownerPresent($0) }) == true
            if let job {
                state["status"] = cancelled ? "cancelled" : "failed_no_auto_retry";state["ended_at"] = utc();state["vpipe_pid"] = NSNull();state["error"] = error.localizedDescription
                try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:job.output_dir + "/status.json"),options:.atomic)
                if fm.fileExists(atPath:job.clip_path) { H3Supervisor.emit(EngineEvent(type:"partial_output",path:job.clip_path)) }
            }
            if !cancelled { H3Supervisor.emit(EngineEvent(type:"error",message:error.localizedDescription)) }
            return cancelled ? 130 : 1
        }
    }
}

private struct ABValidationCancelled: Error {}
private final class ABDecodeCount {
    private let lock = NSLock()
    private var frames = 0,stderr = ""
    func append(_ line: String,stderr isError: Bool) {
        lock.lock();defer { lock.unlock() }
        if isError { if stderr.utf8.count < 4096 { stderr += line + "\n" } }
        else if line.hasPrefix("frame="),let value = Int(line.dropFirst(6).trimmingCharacters(in:.whitespaces)) { frames = max(frames,value) }
    }
    func result() -> (Int,String) { lock.lock();defer { lock.unlock() };return (frames,stderr) }
}
