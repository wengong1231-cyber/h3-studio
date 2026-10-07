import Foundation
import Darwin

@MainActor enum H3HistoryTests {
    static func statusProfile(root: URL,executable: URL) async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath:root.path) else { throw StudioError.invalid("历史核验需使用新的隔离目录。") }
            let started=ProcessInfo.processInfo.systemUptime
            let batch=await Task.detached(priority:.utility) { H3HistoryImporter.known(AppIdentity.modelStatusRoot) }.value
            guard batch.warnings.isEmpty,batch.records.count == 3 else { throw StudioError.invalid(batch.warnings.joined(separator:"；")) }
            let installedState=WorkspaceMigrator.defaultSupportRoot.appendingPathComponent("Workspace/state.json")
            let originalData=try H3Files.read(installedState),original=try JSONDecoder().decode(WorkspaceState.self,from:originalData)
            guard original.queuePaused,original.jobs.count == 2,original.jobs.allSatisfy({ !$0.status.isActive && $0.workerPID == nil }) else { throw StudioError.invalid("当前两条旧记录状态变化，隔离保留核验需重新审查。") }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try originalData.write(to:root.appendingPathComponent("state.json"),options:.withoutOverwriting)
            let store=try TaskStore(root:root,executable:executable,monitoring:false)
            let added=try store.importExternalHistory(batch.records),ids=store.state.jobs.map(\.id)
            let repeated=try store.importExternalHistory(batch.records)
            guard added == 3,repeated == 0,store.state.jobs.map(\.id) == ids,store.launchCount == 0,
                  store.state.jobs.count == 5,store.state.jobs.suffix(3).allSatisfy({ $0.workerPID == nil && $0.workerIdentity == nil && $0.h3Binding == nil && $0.status == .completed && $0.candidate != nil }) else { throw StudioError.invalid("三条只读历史核验未通过。") }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard try encoder.encode(original.jobs) == encoder.encode(Array(store.state.jobs.prefix(2))),
                  try H3Files.read(installedState) == originalData else { throw StudioError.invalid("两条旧记录或当前安装工作区发生变化。") }
            guard batch.records[0].externalHistory?.userSelected == true,batch.records[1].externalHistory?.userSelected == false,
                  batch.records[2].externalHistory?.userSelected == false,batch.records[2].externalHistory?.userRequestedRedo == true,batch.records[2].h3Outcome?.visualReview == "quality_unpassed" else { throw StudioError.invalid("用户采用或S41最新画面审核状态不一致。") }
            let report: [String:Any]=["version":AppIdentity.version,"records":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Array(store.state.jobs.suffix(3)))),
                "added":added,"duplicateAdded":repeated,"stableIDs":true,"launchCount":store.launchCount,
                "previousJobsPreserved":2,"totalJobs":store.state.jobs.count,"installedStateByteUnchanged":true,
                "latestReviewMetadataImported":true,"S41VisualReview":"quality_unpassed","S41UserRequestedRedo":true,"userSelectionFlags":[true,false,false],
                "elapsedMilliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"nativeGUIStarted":false,
                "gpuTasksStarted":0,"installedWorkspaceModified":false,"source":"parent v3 external manifest plus current job/status/output metadata and hashes"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("history-status-profile.json"))
            store.shutdown();FileHandle.standardOutput.write(Data("三条真实外部记录只读核验通过；重复导入新增0条，启动生成0次。\n".utf8));return 0
        } catch { FileHandle.standardError.write(Data(("历史核验失败："+error.localizedDescription+"\n").utf8));return 1 }
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check]=[]
        func check(_ name: String,_ passed: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:passed,detail:detail))
            FileHandle.standardOutput.write(Data("\(passed ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !passed { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        func write(_ url: URL,_ value: [String:Any]) throws { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic) }
        var sentinel: Process?
        do {
            let fm=FileManager.default
            guard !fm.fileExists(atPath:root.path) else { throw StudioError.invalid("History test root must be new") }
            let runtime=try H3Mock.createRuntime(root:root.appendingPathComponent("runtime"),executable:executable)
            let jobURL=try H3Mock.createJob(runtime:runtime),job=try JSONDecoder().decode(H3SingleJob.self,from:H3Files.read(jobURL))
            let directory=jobURL.deletingLastPathComponent(),statusURL=directory.appendingPathComponent("status.json")
            let marker=root.appendingPathComponent("must-not-execute")
            let other=Process();other.executableURL=URL(fileURLWithPath:"/bin/sleep");other.arguments=["40"];try other.run();sentinel=other
            let started="2026-10-05T15:49:02.695519+00:00",ended="2026-10-05T16:04:53.473402+00:00"
            var status: [String:Any]=["job_id":job.job_id,"output_dir":directory.path,"clip_path":job.clip_path,
                "status":"generating","started_at":started,"updated_at":ISO8601DateFormatter().string(from:Date()),
                "latest_progress":"[PROGRESS] 60% of 'vae decode' completed at now (34/56)",
                "controller_pid":other.processIdentifier,"vpipe_pid":other.processIdentifier,
                "command":["/usr/bin/touch",marker.path],"peak_rss_bytes":1048576,"max_cpu_percent":17.6]
            try write(statusURL,status)
            var record=try await Task.detached { try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory)) }.value
            try check("真实外部阶段计数",record.status == .running && record.progress?.completed == 34 && record.progress?.total == 56 && record.endedAt == nil,"读取34/56，未推算整体百分比或结束时间")
            var store: TaskStore?=try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
            _ = try store!.importExternalHistory([record]);let id=store!.state.jobs[0].id
            let duplicate=try store!.importExternalHistory([record])
            try check("稳定jobID与指纹去重",duplicate == 0 && store!.state.jobs.count == 1 && store!.state.jobs[0].id == id && store!.launchCount == 0,"重复导入保持同一UI身份；没有新attempt或进程")
            try check("外部运行与App所有权分离",store!.activeJob == nil && store!.observedJob?.id == id && store!.state.jobs[0].workerPID == nil && store!.state.jobs[0].workerIdentity == nil && !store!.state.jobs[0].canCancelInApp,"历史PID不成为App取消句柄")
            store!.add(.fixture(shot:88,title:"等待外部结束的CPU fixture"))
            let fresh=try H3Mock.createJob(runtime:runtime),freshID=try store!.importH3Job(fresh),binding=store!.state.jobs.last!.h3Binding!
            store!.startQueue();store!.startH3(freshID,approval:.mockForTests(binding.jobSHA256))
            try check("外部运行期间资源保护",!store!.canStart && !store!.canRunH3(freshID) && store!.launchCount == 0,"CPU队列和新H3均未与外部运行抢资源")
            store!.cancel(id);store!.retry(id)
            try check("外部取消重试与命令被阻止",other.isRunning && store!.state.jobs[0].status == .running && !fm.fileExists(atPath:marker.path),"独立进程仍在；记录内command从未执行")
            store!.shutdown();store=nil
            store=try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
            try check("重启保留外部观察状态",store!.state.jobs[0].status == .running && store!.state.jobs[0].id == id && store!.recoveredPIDs.isEmpty && store!.activeJob == nil && store!.launchCount == 0,"外部任务不误报App崩溃，不尝试接管旧PID")
            status["latest_progress"]="[PROGRESS] 'vae decode' ended at now, last reported 98% (55/56)";try write(statusURL,status)
            record=try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory));_ = try store!.importExternalHistory([record])
            try check("阶段结束不补造100%",store!.state.jobs[0].progress == nil && store!.state.jobs[0].status == .running,"98% ended清除进度，尚无终态不推断成功")
            status["status"]="failed_no_auto_retry";status["native_exit_code"]=1;status["ended_at"]=ended;try write(statusURL,status)
            record=try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory));_ = try store!.importExternalHistory([record])
            try check("外部失败刷新同一记录",store!.state.jobs.count == 3 && store!.state.jobs[0].id == id && store!.state.jobs[0].status == .failed && store!.observedJob == nil,"终态保留真实时间；不自动重试")
            var changed=job;changed.seed += 1;try JSONEncoder().encode(changed).write(to:jobURL)
            let altered=try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory))
            try check("同jobID换指纹拒绝替换",rejected { _ = try store!.importExternalHistory([altered]) } && store!.state.jobs[0].externalHistory?.jobSHA256 == record.externalHistory?.jobSHA256,"已核验记录保留，不默默接受变化的job")
            try JSONEncoder().encode(job).write(to:jobURL)
            let alias=directory.appendingPathComponent("alias.json");try fm.createSymbolicLink(at:alias,withDestinationURL:jobURL)
            try check("越界与符号链接拒绝",rejected { _ = try H3HistoryImporter.load(alias,restoreRoot:URL(fileURLWithPath:runtime.workDirectory)) } && rejected { _ = try H3HistoryImporter.load(jobURL,restoreRoot:root.appendingPathComponent("wrong-root")) },"不跟随外部路径或sessions")
            let original=AppIdentity.modelStatusRoot.appendingPathComponent("candidates/shot15-h3-load-check-20261005T154456Z/wanshenji-shot15-h3-candidate.mp4")
            let originalHash=try WorkspaceDigest.sha256(original)
            try fm.copyItem(at:original,to:URL(fileURLWithPath:job.clip_path))
            status["status"]="native_completed_pending_validation";status["native_exit_code"]=0;status["native_completed_at"]=ended;try write(statusURL,status)
            let nativeOnly=try await Task.detached { try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory),expectedClipSHA256:originalHash) }.value
            try check("原生完成与严格质检分离",nativeOnly.status == .completed && nativeOnly.candidate == job.clip_path && nativeOnly.h3Outcome == nil && nativeOnly.externalHistory?.observing == false,"完整当前视频样本和hash通过，可预览；技术检查仍待完成")
            try check("候选指纹变化拒绝成功",rejected { _ = try H3HistoryImporter.load(jobURL,restoreRoot:URL(fileURLWithPath:runtime.workDirectory),expectedClipSHA256:String(repeating:"f",count:64)) },"不把其他视频当作已核验候选")
            var oldReport: [String:Any]=["clip_sha256":originalHash,"source_original_sha256":job.source_image_sha256,
                "strict_full_av_decode":true,"native_lossless_geometry_checked":true,"native_lossless_frames":124,"completed_at":ended]
            try check("旧质检格式需清单绑定",H3HistoryImporter.technicalIdentityMatches(oldReport,job:job,clip:URL(fileURLWithPath:job.clip_path),manifestHash:originalHash,nativeEnd:H3HistoryImporter.date(ended)) && !H3HistoryImporter.technicalIdentityMatches(oldReport,job:job,clip:URL(fileURLWithPath:job.clip_path),manifestHash:nil,nativeEnd:H3HistoryImporter.date(ended)),"旧S41质检只在输出与原输入指纹、帧几何、原生结束时间都绑定后接受")
            oldReport["source_original_sha256"]=String(repeating:"f",count:64)
            try check("旧质检输入变化拒绝",!H3HistoryImporter.technicalIdentityMatches(oldReport,job:job,clip:URL(fileURLWithPath:job.clip_path),manifestHash:originalHash,nativeEnd:H3HistoryImporter.date(ended)),"单独复制同名报告不能核准其他来源")
            var reviewed=nativeOnly;reviewed.h3Outcome=H3Outcome(technicalPass:true,reportPath:"CPU metadata fixture only",simulated:true)
            let review=ExternalHistoryManifest.QualityReview(state:"technical_pass_visual_quality_unpassed",technical_pass:true,natural_motion_pass:false,all124_native_frames_reviewed:true)
            try H3HistoryImporter.applyReview(review,to:&reviewed)
            try check("审核未过不修改生成或用户采用",reviewed.status == .completed && reviewed.h3Outcome?.technicalPass == true && reviewed.h3Outcome?.visualReview == "quality_unpassed" && reviewed.externalHistory?.userSelected == false && reviewed.candidate == nativeOnly.candidate,"技术完成、画面未过和用户待确认独立保存；不新增裁剪或重试")
            var unproven=nativeOnly
            try check("审核不能替代技术证明",rejected { try H3HistoryImporter.applyReview(review,to:&unproven) } && unproven.h3Outcome == nil,"元数据称技术通过不能核准未绑定技术报告")
            let selection=ExternalHistoryManifest.Selection(state:"user_rejected_requested_redo_preserved_history",user_accepted:false,integrated_into_master:false,user_reason:"头部不好看，出水后仍像海底")
            try H3HistoryImporter.applySelection(selection,to:&reviewed)
            try check("拒收刷新同一历史不生成新任务",reviewed.externalHistory?.userRequestedRedo == true && reviewed.externalHistory?.userSelected == false && reviewed.status == .completed && reviewed.id == nativeOnly.id && reviewed.candidate == nativeOnly.candidate,"只修改采用说明，保留任务身份、视频和原执行时间")
            let contradictory=ExternalHistoryManifest.Selection(state:selection.state,user_accepted:true,integrated_into_master:true,user_reason:nil)
            try check("冲突采用元数据拒绝",rejected { try H3HistoryImporter.applySelection(contradictory,to:&reviewed) } && reviewed.externalHistory?.userSelected == false,"要求重做不能同时标为用户已采用")
            try check("只读导入原视频未改",try WorkspaceDigest.sha256(original) == originalHash && !fm.fileExists(atPath:marker.path),"原视频SHA不变；所有命令字段保持数据")
            let before=store!.state.jobs.count;store!.shutdown();_ = try store!.importExternalHistory([nativeOnly])
            try check("退出后拒绝迟到导入",store!.state.jobs.count == before && store!.state.jobs[0].status == .failed,"后台任务迟到不覆写退出后的状态")
            other.terminate();other.waitUntilExit();sentinel=nil
            let report: [String:Any]=["version":AppIdentity.version,"passed":checks.count,"checks":try JSONSerialization.jsonObject(with:JSONEncoder().encode(checks)),
                "gpuTasksStarted":0,"nativeGUIStarted":false,"sourceVideoReadOnly":true,"installedWorkspaceModified":false]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("history-test-report.json"))
            return 0
        } catch {
            if let sentinel,sentinel.isRunning { sentinel.terminate();sentinel.waitUntilExit() }
            FileHandle.standardError.write(Data(("History regression failed: "+error.localizedDescription+"\n").utf8))
            if let data=try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("history-test-report.json")) }
            return 1
        }
    }
}
