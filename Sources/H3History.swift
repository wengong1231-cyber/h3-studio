import Foundation
import AVFoundation
import CryptoKit

struct ExternalH3History: Codable, Equatable {
    var nativeJobID: String
    var jobPath: String
    var jobSHA256: String
    var statusSHA256: String
    var technicalSHA256: String?
    var clipSHA256: String?
    var nativeLog: String?
    var userSelected: Bool
    var selectionSource: String
    var nativeElapsedSeconds: Double?
    var reportedCPUPercent: Double?
    var sourceStatus: String
    var statusUpdatedAt: Date?
    var observing: Bool
    var integratedIntoMaster: Bool?
    var originalStartedAtUTC: String?
    var originalEndedAtUTC: String?
    var userRequestedRedo: Bool?
    var userReason: String?
}

// Compressed samples bind the current video to its existing decode receipt.
// History import never runs a decoder process, generates, or rewrites media.
struct HistoricalClipAudit {
    var width: Int; var height: Int; var frames: Int; var fps: Double; var duration: Double
    static func capture(_ url: URL) throws -> Self {
        let asset=AVURLAsset(url:url,options:[AVURLAssetPreferPreciseDurationAndTimingKey:true])
        guard let track=asset.tracks(withMediaType:.video).first,track.preferredTransform == .identity else {
            throw StudioError.invalid("历史候选缺少可核对的原始视频轨。")
        }
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else { throw StudioError.invalid("无法核对历史视频样本。") }
        reader.add(output);guard reader.startReading() else { throw StudioError.invalid("历史视频读取器未启动。") }
        var count=0,duration=0.0
        while let sample=output.copyNextSampleBuffer() {
            let samples=CMSampleBufferGetNumSamples(sample)
            // AVFoundation returns zero-sample container boundary markers too.
            guard samples>0 else { continue }
            for index in 0..<samples {
                var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.invalid,decodeTimeStamp:.invalid)
                guard CMSampleBufferGetSampleTimingInfo(sample,at:index,timingInfoOut:&timing) == noErr,
                      timing.presentationTimeStamp.seconds.isFinite,timing.duration.seconds.isFinite,
                      timing.duration.seconds>0,count<200_000 else {
                    reader.cancelReading();throw StudioError.invalid("历史视频帧时间信息无效。")
                }
                count += 1;duration += timing.duration.seconds
            }
        }
        guard reader.status == .completed,count>0 else { throw StudioError.invalid("历史视频样本未完整读取。") }
        // MP4 headers may round 124/24 to 5.167. Sum actual sample durations.
        return Self(width:Int(track.naturalSize.width),height:Int(track.naturalSize.height),frames:count,fps:Double(track.nominalFrameRate),duration:duration)
    }
}

struct H3HistoryBatch { var records: [ShotJob];var warnings: [String] }

struct ExternalHistoryManifest: Decodable {
    struct Paths: Decodable { var job: String;var status: String;var video: String }
    struct Execution: Decodable {
        var native_terminal: Bool;var native_success: Bool;var native_exit_code: Int
        var started_at_UTC: String;var ended_at_UTC: String
    }
    struct Output: Decodable { var sha256: String }
    struct Selection: Decodable {
        var state: String;var user_accepted: Bool;var integrated_into_master: Bool
        var user_reason: String?
    }
    struct QualityReview: Decodable {
        var state: String;var technical_pass: Bool;var natural_motion_pass: Bool;var all124_native_frames_reviewed: Bool
    }
    struct Record: Decodable {
        var record_id: String;var stable_job_id: String;var shot_number: Int
        var import_only: Bool;var app_launched: Bool;var app_may_replay_or_enqueue: Bool;var app_may_signal_recorded_pid: Bool
        var paths: Paths;var execution: Execution;var output: Output;var selection: Selection
        var quality_review: QualityReview?
    }
    var schema: String;var records: [Record]
}

enum H3HistoryImporter {
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func date(_ value: Any?) -> Date? {
        guard let value=value as? String else { return nil }
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return parser.date(from:value) ?? ISO8601DateFormatter().date(from:value)
    }
    static func technicalIdentityMatches(_ report: [String:Any],job: H3SingleJob,clip: URL,manifestHash: String?,nativeEnd: Date?) -> Bool {
        if report["job_id"] as? String == job.job_id && report["clip_path"] as? String == clip.path {
            return report["strict_full_av_decode"] as? String == "pass"
        }
        // The parent's S41 validator predates the jobID/path receipt fields.
        // Accept that exact format only when the v3 import manifest binds its
        // output hash, original input hash, native geometry, and completion time.
        guard let manifestHash,let nativeEnd,let completed=date(report["completed_at"]) else { return false }
        return report["job_id"] == nil && report["clip_path"] == nil &&
            report["clip_sha256"] as? String == manifestHash && report["source_original_sha256"] as? String == job.source_image_sha256 &&
            report["strict_full_av_decode"] as? Bool == true && report["native_lossless_geometry_checked"] as? Bool == true &&
            report["native_lossless_frames"] as? Int == job.profile.frames && completed >= nativeEnd
    }
    static func applyReview(_ review: ExternalHistoryManifest.QualityReview?,to record: inout ShotJob) throws {
        guard let review else { return }
        guard !review.technical_pass || record.h3Outcome?.technicalPass == true else {
            throw StudioError.invalid("外部审核声称技术通过，但当前候选技术证明未通过。")
        }
        if !review.natural_motion_pass {
            record.h3Outcome?.visualReview="quality_unpassed"
            record.stage=record.externalHistory?.userSelected == true ? "此前 CLI 生成 · 用户已接受已知画面限制" : "此前 CLI 生成 · 技术完成，画面审查未过，待用户确认"
            record.logTail.append("外部画面审查未过；是否采用以用户决定为准，不自动重试或裁剪。")
        }
    }
    static func applySelection(_ selection: ExternalHistoryManifest.Selection,to record: inout ShotJob) throws {
        guard selection.state == "user_rejected_requested_redo_preserved_history" else { return }
        guard !selection.user_accepted,!selection.integrated_into_master else { throw StudioError.invalid("用户重做决定与采用标记冲突，保留原状态。") }
        record.externalHistory?.userRequestedRedo=true
        record.externalHistory?.userReason=selection.user_reason.map { String($0.prefix(500)) }
        record.h3Outcome?.selectedForProduction=false
        record.stage="此前 CLI 生成 · 技术完成，用户要求重做"
        record.title=String(format:"S%02d · 此前 CLI 生成 · 用户要求重做",record.shot)
        record.logTail.append("用户已拒收并要求重做；保留本条历史和原片，不再询问是否采用旧片，不自动生成新任务。")
    }
    static func load(_ url: URL,restoreRoot: URL,expectedClipSHA256: String? = nil,userSelected: Bool = false,selectionSource: String = "待画面确认",integratedIntoMaster: Bool = false) throws -> ShotJob {
        _ = try H3Files.inside(url.path,restoreRoot.path+"/candidates")
        guard url.lastPathComponent == "job.json" else { throw StudioError.invalid("外部历史只接受候选目录中的 job.json。") }
        let data=try H3Files.read(url,limit:2_097_152),job=try JSONDecoder().decode(H3SingleJob.self,from:data)
        let directory=url.deletingLastPathComponent(),jobHash=hash(data)
        guard job.version == 1,job.work_dir == restoreRoot.path,job.output_dir == directory.path,
              !job.job_id.isEmpty,job.job_id.utf8.count<512,(1...999).contains(job.shot_number),
              job.model_ref == ModelValidationContext.modelKey,job.lora_ref == ModelValidationContext.loraKey,
              job.profile == .approved,ModelStatusReader.isHash(job.prompt_sha256,length:64) else {
            throw StudioError.invalid("外部历史的候选目录、身份、模型或参数不匹配。")
        }
        let clip=try H3Files.inside(job.clip_path,directory.path)
        let statusURL=directory.appendingPathComponent("status.json"),technicalURL=directory.appendingPathComponent("technical-validation.json")
        let statusData=try H3Files.read(statusURL,limit:2_097_152)
        guard let status=try JSONSerialization.jsonObject(with:statusData) as? [String:Any],
              status["job_id"] as? String == job.job_id,status["output_dir"] as? String == directory.path,
              status["clip_path"] as? String == clip.path,let started=date(status["started_at"]),
              let phase=status["status"] as? String,!phase.isEmpty else {
            throw StudioError.invalid("外部状态与 job 身份或实际开始时间不匹配。")
        }
        if let profile=status["profile"] as? [String:Any] {
            let decoded=try JSONDecoder().decode(H3Profile.self,from:JSONSerialization.data(withJSONObject:profile))
            guard decoded == job.profile else { throw StudioError.invalid("外部状态中的模型参数与 job 不匹配。") }
        }
        let technicalCompleted=["completed_reviewed_candidate","technical_pass_visual_review_pending"].contains(phase)
        let completed=technicalCompleted || (phase == "native_completed_pending_validation" && status["native_exit_code"] as? Int == 0 && date(status["native_completed_at"]) != nil && expectedClipSHA256 != nil)
        let failed=["failed","failed_no_auto_retry","cancelled","cancelled_by_user","aborted","timed_out"].contains(phase)
        let running=["starting","generating","validating","native_completed_pending_validation"].contains(phase)
        let nativeEnd=date(status["native_completed_at"]) ?? date(status["completed_at"]) ?? date(status["ended_at"])
        if let nativeEnd,nativeEnd<started { throw StudioError.invalid("外部任务结束时间早于开始时间。") }
        var record=ShotJob(shot:job.shot_number,segment:job.segment_id,title:String(format:"S%02d · 此前 CLI 生成",job.shot_number),prompt:"冻结提示词 SHA-256："+job.prompt_sha256,requestedDuration:Double(job.profile.frames)/Double(job.profile.fps),engine:.h3,status:completed ? .completed : failed ? .failed : running ? .running : .blocked)
        record.importKey="external-h3:"+job.job_id+":"+jobHash
        record.startedAt=started;record.endedAt=(completed || failed) ? nativeEnd : nil;record.createdAt=started
        record.updatedAt=date(status["updated_at"]) ?? started
        record.parameters=GenerationParameters(width:job.profile.width,height:job.profile.height,frames:job.profile.frames,steps:job.profile.steps,fps:Double(job.profile.fps),model:"MiniMax H3 FL2VA 8-bit / Turbo LoRA v4",verified:true)
        var technicalHash: String?,clipHash: String?,resources: [String:Any]=[:]
        if completed {
            try ModelStatusReader.requireFile(clip,limit:2_147_483_647)
            let actualHash=try WorkspaceDigest.sha256(clip)
            guard expectedClipSHA256 == nil || actualHash == expectedClipSHA256 else { throw StudioError.invalid("外部候选与导入清单指纹不匹配。") }
            let media=try HistoricalClipAudit.capture(clip)
            guard media.frames == job.profile.frames,media.width == job.profile.width,media.height == job.profile.height,
                  abs(media.fps-Double(job.profile.fps))<0.0001,abs(media.duration-record.requestedDuration)<0.0001 else {
                throw StudioError.invalid("历史候选当前样本、尺寸或时间轴与 job 不匹配。")
            }
            record.candidate=clip.path;clipHash=actualHash;record.progress=nil
            record.title += userSelected ? " · 已选用" : " · 备选"
            record.stage=userSelected ? "此前 CLI 生成 · 用户已选用" : "此前 CLI 生成 · 原生已结束，待质检与确认"
            if FileManager.default.fileExists(atPath:technicalURL.path) {
            let technicalData=try H3Files.read(technicalURL,limit:2_097_152)
            guard let technical=try JSONSerialization.jsonObject(with:technicalData) as? [String:Any],
                  technicalIdentityMatches(technical,job:job,clip:clip,manifestHash:expectedClipSHA256,nativeEnd:nativeEnd),
                  technical["native_exit_code"] as? Int == 0,status["native_exit_code"] as? Int == 0,
                  status["generation_process_alive"] as? Bool != true,nativeEnd != nil,
                  technical["decoded_video_frames"] as? Int == job.profile.frames,
                  technical["dimensions"] as? [Int] == [job.profile.width,job.profile.height],technical["fps"] as? Int == job.profile.fps,
                  let expected=technical["clip_sha256"] as? String,ModelStatusReader.isHash(expected,length:64),
                  expectedClipSHA256 == nil || expected == expectedClipSHA256 else {
                throw StudioError.invalid("外部完成记录尚未取得一致的技术验证。")
            }
            try ModelStatusReader.requireFile(clip,bytes:(technical["clip_size_bytes"] as? NSNumber)?.int64Value,limit:2_147_483_647)
            guard actualHash == expected else { throw StudioError.invalid("外部候选与技术验证指纹不匹配。") }
            let duration=(technical["video_duration_seconds"] as? NSNumber)?.doubleValue ?? record.requestedDuration
            guard media.frames == job.profile.frames,media.width == job.profile.width,media.height == job.profile.height,
                  abs(media.fps-Double(job.profile.fps))<0.0001,abs(media.duration-duration)<0.0001 else {
                throw StudioError.invalid("历史候选当前帧数、尺寸或时间轴与技术记录不匹配。")
            }
            record.candidate=clip.path;record.requestedDuration=duration
            record.stage=userSelected ? "此前 CLI 生成 · 用户已选用" : "此前 CLI 生成 · 技术通过，备选待确认"
            record.h3Outcome=H3Outcome(technicalPass:true,visualReview:userSelected ? "accepted_by_user" : "pending",selectedForProduction:userSelected,reportPath:technicalURL.path,simulated:technical["simulated"] as? Bool ?? false)
            resources=technical["resources"] as? [String:Any] ?? [:]
            if let summary=technical["resource_summary"] as? [String:Any],let peak=summary["peak_RSS_bytes"] { resources["peak_ps_rss_bytes"]=peak }
            technicalHash=hash(technicalData);clipHash=expected
            } else if technicalCompleted { throw StudioError.invalid("外部状态称技术通过，但验证报告缺失。") }
        } else if failed {
            record.stage="此前 CLI 生成 · 外部失败，未自动重试"
            record.error=status["error"] as? String ?? "外部状态为 "+phase+"；原输出与日志保留。"
        } else {
            record.stage="此前 CLI 生成 · 外部状态："+phase
            if let line=status["latest_progress"] as? String,let event=H3Progress.event(line) {
                record.stage="此前 CLI 生成 · "+(event.stage ?? phase)
                if event.type == "progress",let done=event.completed,let total=event.total,total>0,done>=0,done<=total {
                    record.progress=StageProgress(completed:done,total:total,unit:event.unit ?? "阶段单位")
                }
            }
            if let updated=date(status["updated_at"]),Date().timeIntervalSince(updated)>45 {
                record.stage="外部状态更新已延迟 · 最后阶段："+record.stage
            }
        }
        let log=directory.appendingPathComponent("record/native-run.log")
        let nativeLog=(try? ModelStatusReader.requireFile(log,limit:16_777_216)) != nil ? log.path : nil
        let nativeElapsed=(status["native_elapsed_seconds"] as? NSNumber)?.doubleValue ?? (status["elapsed_seconds"] as? NSNumber)?.doubleValue
        let cpu=(resources["peak_ps_reported_cpu_percent"] as? NSNumber)?.doubleValue ?? (status["max_cpu_percent"] as? NSNumber)?.doubleValue
        record.externalHistory=ExternalH3History(nativeJobID:job.job_id,jobPath:url.path,jobSHA256:jobHash,statusSHA256:hash(statusData),technicalSHA256:technicalHash,clipSHA256:clipHash,nativeLog:nativeLog,userSelected:completed && userSelected,selectionSource:selectionSource,nativeElapsedSeconds:nativeElapsed,reportedCPUPercent:cpu,sourceStatus:phase,statusUpdatedAt:date(status["updated_at"]),observing:!completed && !failed,integratedIntoMaster:integratedIntoMaster,originalStartedAtUTC:status["started_at"] as? String,originalEndedAtUTC:(status["native_completed_at"] ?? status["completed_at"] ?? status["ended_at"]) as? String)
        var attempt=Attempt(number:1,startedAt:started,endedAt:record.endedAt,status:record.status,directory:directory.path,candidate:record.candidate)
        attempt.parameters=record.parameters
        attempt.peaks.samples=resources["samples"] as? Int ?? (status["latest_resource_sample"] == nil ? 0 : 1)
        let rss=(resources["peak_ps_rss_bytes"] as? NSNumber)?.doubleValue ?? (status["peak_rss_bytes"] as? NSNumber)?.doubleValue
        attempt.peaks.workerRSSMB=rss.map { $0/1_048_576 };record.attempts=[attempt]
        record.logTail=["来源：此前 CLI 生成；开始 "+(status["started_at"] as! String),"外部状态："+phase,"只读引用原候选；不执行 job.command，不取得旧 PID，不取消或重投外部进程。"]
        if let lines=status["progress_events"] as? [[String:Any]] {
            record.logTail += lines.suffix(15).compactMap { item in (item["line"] as? String).map { (item["at"] as? String ?? "")+" "+$0 } }
        }
        if completed { record.logTail.append(userSelected ? "用户已选用（"+selectionSource+"）；导入未修改正式成片。" : technicalHash != nil ? "技术通过；备选视频尚未采用。" : "原生退出0、候选文件指纹与视频样本已核对；严格技术检查和画面确认仍待完成。") }
        return record
    }
    static func known(_ root: URL) -> H3HistoryBatch {
        guard root == AppIdentity.modelStatusRoot else { return H3HistoryBatch(records:[],warnings:["已核历史必须使用原恢复位置。"]) }
        var batch=H3HistoryBatch(records:[],warnings:[])
        do {
            let manifestURL=try H3Files.inside(root.appendingPathComponent("app-external-records-20261006/manifest.json").path,root.path)
            let manifest=try JSONDecoder().decode(ExternalHistoryManifest.self,from:H3Files.read(manifestURL,limit:2_097_152))
            guard manifest.schema == "jingsheng-external-record-import-v3",manifest.records.count == 3 else { throw StudioError.invalid("外部导入契约版本或记录数不匹配。") }
            var ids=Set<String>()
            for item in manifest.records {
                guard ids.insert(item.stable_job_id).inserted,item.import_only,!item.app_launched,!item.app_may_replay_or_enqueue,!item.app_may_signal_recorded_pid,
                      item.record_id == "external-cli:"+item.stable_job_id,
                      item.paths.status == URL(fileURLWithPath:item.paths.job).deletingLastPathComponent().appendingPathComponent("status.json").path,
                      ModelStatusReader.isHash(item.output.sha256,length:64),item.execution.native_terminal,item.execution.native_success,item.execution.native_exit_code == 0,
                      date(item.execution.started_at_UTC) != nil,date(item.execution.ended_at_UTC) != nil else { throw StudioError.invalid("外部清单身份、导入权限或终态证明不匹配。") }
                var record=try load(URL(fileURLWithPath:item.paths.job),restoreRoot:root,expectedClipSHA256:item.output.sha256,userSelected:item.selection.user_accepted,selectionSource:item.selection.state,integratedIntoMaster:item.selection.integrated_into_master)
                guard record.externalHistory?.nativeJobID == item.stable_job_id,record.candidate == item.paths.video,record.startedAt == date(item.execution.started_at_UTC),
                      record.endedAt == date(item.execution.ended_at_UTC),record.shot == item.shot_number else { throw StudioError.invalid("当前 job/status/output 与父任务清单不一致。") }
                try applyReview(item.quality_review,to:&record)
                try applySelection(item.selection,to:&record)
                batch.records.append(record)
            }
        } catch { batch.warnings.append("父任务外部记录清单："+error.localizedDescription) }
        return batch
    }
}

extension TaskStore {
    @discardableResult func importExternalHistory(_ records: [ShotJob],announce: Bool = true) throws -> Int {
        guard !shuttingDown else { return 0 }
        var next=state.jobs,added=0
        for var record in records {
            guard record.engine == .h3,let source=record.externalHistory,record.importKey != nil,record.h3Binding == nil,
                  record.workerPID == nil,record.workerIdentity == nil else { throw StudioError.invalid("导入记录不是只读外部历史。") }
            record.progress=record.status.isActive ? record.progress : nil
            if let index=next.firstIndex(where: { $0.externalHistory?.nativeJobID == source.nativeJobID || $0.h3Binding?.nativeJobID == source.nativeJobID }) {
                guard next[index].externalHistory?.jobSHA256 == source.jobSHA256 else { throw StudioError.invalid("同一 jobID 已有不同指纹或应用自有任务，未替换。") }
                record.id=next[index].id;next[index]=record
            } else { next.append(record);added += 1 }
        }
        guard next.count<=2000 else { throw StudioError.invalid("历史导入超过工作区记录上限。") }
        state.jobs=next
        if added>0,let first=records.first,let target=state.jobs.first(where: { $0.importKey == first.importKey }) { selectedID=target.id }
        if announce { notice="已只读导入 \(added) 条新记录；已有任务仅刷新状态，未创建生成进程。" }
        persist();return added
    }
    func importKnownHistoryInBackground(announce: Bool = true) {
        guard !shuttingDown,!historyImportInFlight,!abConfigurationBusy,abWorkflowID == nil,
              locations.modelStatusRoot == AppIdentity.modelStatusRoot.path else { return }
        historyImportInFlight=true
        Task { [weak self] in
            let batch=await Task.detached(priority:.utility) { H3HistoryImporter.known(AppIdentity.modelStatusRoot) }.value
            guard let self else { return };self.historyImportInFlight=false
            guard !self.shuttingDown else { return }
            do {
                _ = try self.importExternalHistory(batch.records,announce:announce)
                if !batch.warnings.isEmpty { self.notice="部分外部记录待核对："+batch.warnings.joined(separator:"；") }
            } catch { self.notice="外部历史导入待核对："+error.localizedDescription }
        }
    }
    func startBackgroundHistory() {
        guard !shuttingDown,historyTimer == nil,locations.modelStatusRoot == AppIdentity.modelStatusRoot.path else { return }
        importKnownHistoryInBackground()
        historyTimer=Timer.scheduledTimer(withTimeInterval:8,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Selection/review metadata may change after native completion.
                // This is a refresh, never a whole-manifest hash allowlist.
                self.importKnownHistoryInBackground(announce:false)
            }
        }
    }
}
