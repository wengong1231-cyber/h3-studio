import Foundation

enum ExecutionActivitySelfTests {
    static func run(root: URL) -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
        }
        let start = Date(timeIntervalSince1970:1000)
        var a = ExecutionActivity(stage:"加载模型",at:start)
        a.observe(.init(type:"log",message:"still alive"),at:start.addingTimeInterval(60))
        check("日志不伪装真实进展",a.lastProgressAt == start,"log traffic is separate from business advancement")
        a.observe(.init(type:"heartbeat"),at:start.addingTimeInterval(130))
        check("心跳仅更新存活时间",a.lastProgressAt == start && a.lastHeartbeatAt == start.addingTimeInterval(130),"heartbeat cannot hide quiet loading")
        var job = ShotJob.fixture(shot:1,title:"activity fixture");job.status = .running;job.stage = "加载模型";job.startedAt = start;job.executionActivity = a
        let quiet = ActivityPresenter.job(job,now:start.addingTimeInterval(140))
        check("长加载显式无新进展",quiet.shortState == "无进展" && quiet.tone == .attention && quiet.progress == nil,"fresh heartbeat does not fabricate loading percent or prove responsiveness")
        let dead = ActivityPresenter.job(job,now:start.addingTimeInterval(200))
        check("无心跳单独提示",dead.state.contains("未收到近期心跳"),"no automatic restart, cancellation or definite deadlock claim")
        a.observe(.init(type:"progress",stage:"采样生成",completed:1,total:4,unit:"步"),at:start.addingTimeInterval(210))
        a.observe(.init(type:"progress",stage:"采样生成",completed:1,total:4,unit:"步"),at:start.addingTimeInterval(220))
        a.observe(.init(type:"progress",stage:"采样生成",completed:0,total:4,unit:"步"),at:start.addingTimeInterval(230))
        check("重复与回退计数不更新时间",a.lastProgressAt == start.addingTimeInterval(210) && a.lastCount == 1,"only actual stage or count advances mark progress")
        a.observe(.init(type:"progress",completed:5,total:4),at:start.addingTimeInterval(240))
        check("非法计数不记录进展",a.lastCount == 1 && a.lastProgressAt == start.addingTimeInterval(210),"out-of-range counts rejected")
        a.observe(.init(type:"progress",stage:"检查源视频指纹",completed:32_000_000,total:100_000_000,unit:"字节"),at:start.addingTimeInterval(250))
        check("实际源文件字节进度可记录",a.lastCount == 32_000_000 && a.lastProgressAt == start.addingTimeInterval(250),"real source hashing remains measured even above one million bytes")
        a.observe(.init(type:"native_started"),at:start.addingTimeInterval(260))
        check("启动进程不猜测已加载模型",a.phase == .starting && a.rawStage.contains("等待阶段上报"),"native process start is not model-load evidence")
        a.observe(.init(type:"stage",stage:"未识别的 engine op 7"),at:start.addingTimeInterval(270))
        check("未知阶段保留原始名称",a.phase == .processing && a.rawStage == "未识别的 engine op 7","no inferred loading or percent")
        check("阶段映射",ExecutionPhase.from("sampling") == .sampling && ExecutionPhase.from("vae decoding") == .decoding && ExecutionPhase.from("encoding mp4") == .encoding && ExecutionPhase.from("validation") == .validating,"stage labels come from real events")
        let last = a.lastProgressAt
        a.milestone("正在取消",at:start.addingTimeInterval(280),phase:.cancelling)
        a.finish(.cancelled,stage:"已取消",at:start.addingTimeInterval(290))
        a.observe(.init(type:"progress",stage:"sampling",completed:4,total:4),at:start.addingTimeInterval(300))
        check("取消和迟到事件不伪装推进",a.lastProgressAt == last && a.phase == .cancelled,"terminal activity freezes business evidence")
        job.status = .cancelled;job.stage = "已取消";job.endedAt = start.addingTimeInterval(290);job.executionActivity = a
        let end1 = ActivityPresenter.job(job,now:start.addingTimeInterval(400)),end2 = ActivityPresenter.job(job,now:start.addingTimeInterval(900))
        check("终态停止计时",end1.elapsed == end2.elapsed && end1.lastProgress == end2.lastProgress && end1.progress == nil,"ended tasks do not keep counting")
        job.status = .running;job.endedAt = nil;job.executionActivity = nil;job.stage = "旧记录";job.progress = nil
        let legacy = ActivityPresenter.job(job,now:start.addingTimeInterval(900))
        check("旧记录不推断停滞",legacy.tone == .working && legacy.detail.contains("不能据此判断停滞"),"missing timestamp is unknown, not invented from updatedAt")
        job.status = .blocked;job.h3AutomaticWorkflow = .init(status:"waiting",phase:"pixel_qa",startedAt:start,automaticContinuationAuthorized:true)
        let qa = ActivityPresenter.job(job,now:start.addingTimeInterval(20))
        check("助手图审与GPU执行区分",qa.shortState == "待检查" && qa.tone == .waiting && qa.detail.contains("没有运行视频生成"),"no operator approval step or fake spinner")
        job.h3AutomaticWorkflow = nil;job.status = .interrupted;job.error = "crash fixture"
        let interrupted = ActivityPresenter.job(job,now:start.addingTimeInterval(20))
        check("中断不是运行",interrupted.shortState == "中断" && interrupted.tone == .attention && interrupted.progress == nil,"no native replay implied")
        let read = ActivityPresenter.fileRead(operation:"下载清单",started:start,lastStep:start,timedOut:true,now:start.addingTimeInterval(9))
        check("读取超时可见",read.shortState == "读超时" && read.state.contains("读取超时") && read.progress == nil && read.detail.contains("没有叠加"),"timeout stays unconfirmed; no ready override")
        let denied = ActivityPresenter.fileRead(operation:"下载清单",started:start,lastStep:start,timedOut:false,accessDenied:true,now:start.addingTimeInterval(9))
        check("被拒访问不等于已准备",denied.shortState == "待授权" && denied.tone == .attention,"typed error is not inferred from old TCC history")
        let trace = ModelReadTrace();trace.begin(at:start);trace.step("download manifest","download-manifest.json",at:start.addingTimeInterval(1));trace.step("download manifest","download-manifest.json",at:start.addingTimeInterval(2))
        check("状态轮询不刷新读取推进",trace.snapshot?.lastStepAt == start.addingTimeInterval(1),"same operation is not a new milestone")
        trace.finish(at:start.addingTimeInterval(3))
        check("完成读取时点保留",trace.snapshot?.endedAt == start.addingTimeInterval(3),"trace does not touch model files")
        do {
            let bytes = try JSONEncoder().encode(a),decoded = try JSONDecoder().decode(ExecutionActivity.self,from:bytes)
            check("真实时点持久化",decoded == a,"restart preserves stage, business progress and separate heartbeat")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try JSONEncoder().encode(checks).write(to:root.appendingPathComponent("test-report.json"),options:.atomic)
        } catch { check("保存报告",false,error.localizedDescription) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
