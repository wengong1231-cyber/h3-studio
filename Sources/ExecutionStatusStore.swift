import Foundation

extension ActivityPresenter {
    static func fileRead(operation: String,started: Date?,lastStep: Date?,timedOut: Bool,accessDenied: Bool = false,now: Date) -> ActivityPresentation {
        let elapsed = started.map { duration(now.timeIntervalSince($0)) } ?? "开始时间未记录"
        return .init(state:accessDenied ? "文件访问被拒绝 · 等待授权核对" : timedOut ? "读取超时 · 等待文件访问返回" : "后台核对中",
            stage:operation,detail:accessDenied ? "当前文件访问未获允许，没有启动生成。" : timedOut ? "读取尚未返回；当前状态未确认，没有叠加第二次读取。" : "正在核对本地文件；尚未启动生成。",
            elapsed:elapsed,stageElapsed:nil,lastProgress:lastStep.map { "最后读取推进 " + age($0,now:now) } ?? "读取推进时间未记录",heartbeat:nil,
            nextStep:timedOut || accessDenied ? "查看已出现的 macOS 文件访问提示或日志；若没有提示，先定位等待。不要重复启动任务。" : nil,
            tone:timedOut || accessDenied ? .attention : .working,progress:nil,symbol:timedOut || accessDenied ? "exclamationmark.triangle" : "doc.text.magnifyingglass",
            shortState:accessDenied ? "待授权" : timedOut ? "读超时" : "读取")
    }
}

extension TaskStore {
    var statusDisplayJob: ShotJob? {
        displayedActiveJob ?? state.jobs.first(where:{ $0.status.isPending && $0.h3AutomaticWorkflow?.phase == "pixel_qa" })
    }
    func workbenchActivity(at now: Date = Date()) -> ActivityPresentation {
        if let job = statusDisplayJob { return ActivityPresenter.job(job,now:now,automaticLaunchesPaused:state.automaticLaunchesPaused == true) }
        if let fault = storageFault {
            return .init(state:"工作区保存失败 · 队列暂停",stage:"保存任务状态",detail:fault,elapsed:"未启动",stageElapsed:nil,
                lastProgress:"没有新生成进展",nextStep:"查看工作区空间与文件权限，保留原状态和候选。",tone:.failure,symbol:"exclamationmark.circle",shortState:"保存失败")
        }
        if readiness.phase == .timedOut || readiness.lastFailure == .accessDenied {
            let trace = readiness.currentRead
            return ActivityPresenter.fileRead(operation:(trace?.operation ?? "读取恢复状态") + (trace?.file.map { " · " + $0 } ?? ""),
                started:trace?.startedAt,lastStep:trace?.lastStepAt,timedOut:readiness.phase == .timedOut,accessDenied:readiness.lastFailure == .accessDenied,now:now)
        }
        if abConfigurationBusy || backgroundReadVisible(at:now) {
            let started = abConfigurationBusy ? configurationReadStartedAt : historyImportInFlight ? historyReadStartedAt : videoReviewReadStartedAt
            return ActivityPresenter.fileRead(operation:abConfigurationBusy ? configurationReadOperation : historyImportInFlight ? "核对已有生成记录" : "核对用户视频接受回执与原生端帧",started:started,lastStep:started,
                timedOut:started.map { now.timeIntervalSince($0) >= 8 } == true,now:now)
        }
        if !recoveredPIDs.isEmpty {
            return .init(state:"等待原自有进程安全退出",stage:"恢复中断任务",detail:"旧进程尚未退出，当前不会启动第二个生成。",elapsed:"未启动",stageElapsed:nil,
                lastProgress:"原进展记录保留",nextStep:"查看中断任务日志并等待监督器清理。",tone:.attention,symbol:"clock.badge.exclamationmark",shortState:"待恢复")
        }
        if let selected,selected.status.isPending {
            var p = activity(for:selected,at:now)
            p.state = "当前没有生成 · " + p.state
            return p
        }
        if let selected,selected.status == .completed,selected.h3QueuePlan != nil,selected.supersededBy == nil {
            return activity(for:selected,at:now)
        }
        return .init(state:"当前没有生成任务",stage:pendingCount == 0 ? "所有已登记任务均已结束" : "\(pendingCount) 段待准备或等待前段",
            detail:"模型准备和整机 GPU 使用率不代表正在生成镜头。",elapsed:"未启动",stageElapsed:nil,lastProgress:"未领取新的生成任务",
            nextStep:pendingCount == 0 ? "查看已完成的候选与日志。" : "选择待准备镜头，查看其具体条件。",tone:.waiting,symbol:"clock",shortState:"待准备")
    }
    func activity(for job: ShotJob,at now: Date = Date()) -> ActivityPresentation {
        if actionRevisionID == job.id { return workbenchActivity(at:now) }
        if job.status.isPending,job.h3AutomaticWorkflow == nil,
           abConfigurationBusy || backgroundReadVisible(at:now) || readiness.phase == .timedOut || readiness.lastFailure == .accessDenied || storageFault != nil {
            return workbenchActivity(at:now)
        }
        if job.status.isPending,job.h3FirstProposal == nil,let request = job.h3QueuePlan?.dependencyRequestID,
           let previous = currentPlannedJob(request) {
            var p = ActivityPresenter.job(job,now:now,automaticLaunchesPaused:state.automaticLaunchesPaused == true)
            if previous.status == .completed,previous.h3Outcome?.technicalPass == true {
                if previous.h3VideoRejection != nil {
                    p.state = "前段候选已拒绝 · 等待重做";p.shortState = "已拒绝";p.tone = .attention
                    p.detail = previous.h3VideoRejection!.reason
                    p.nextStep = "旧接受、端点和QA不能接续；在前段重做或整镜重做后准备新输入。"
                } else if previous.videoContinuationAuthorized {
                    p.state = "首段已接受 · 可以准备续段";p.shortState = "可接续"
                    p.detail = "已绑定 \(previous.shortID) 第\(previous.h3QueuePlan!.part)段所选视频与 raw\(job.h3QueuePlan!.dependencyRawIndex!) 原生端帧。"
                    p.nextStep = "准备本段后由助手检查输入，再自动生成一次。"
                } else {
                    p.state = "等待前段候选接受";p.shortState = "待接受"
                    p.detail = "前段技术检查通过，等待接受所选窗口与原生端帧；图片检查由助手完成。"
                    p.nextStep = "在前段结果中接受并继续即可接续，无需聊天里重复确认。"
                }
            } else {
                p.detail = "依赖 \(previous.shortID) 第\(previous.h3QueuePlan!.part)段 · " + previous.displayStatusLabel
            }
            return p
        }
        if job.status == .completed,let plan = job.h3QueuePlan {
            var p = ActivityPresenter.job(job,now:now,automaticLaunchesPaused:state.automaticLaunchesPaused == true)
            p.stage = "\(job.shortID) 第\(plan.part)段 · 候选已保存"
            if job.supersededBy != nil {
                p.state = "原候选已重做 · 历史保留";p.shortState = "历史";p.tone = .waiting
                p.nextStep = "后续只绑定当前重做任务的输出；原候选、检查和日志保留。"
            } else if let rejected = job.h3VideoRejection {
                p.state = rejected.actorKind == "user" ? "用户已拒绝候选 · 等待重做" : "候选已拒绝 · 界面来源记录";p.shortState = "已拒绝";p.tone = .attention
                p.detail = rejected.reason;p.nextStep = "重做会成为此任务的新版本；拒绝原因和原候选留在历史中，续段等待新版通过验收。"
            } else if job.h3VideoReview?.isTrustedAcceptance == true {
                p.state = "本段已接受 · 风险与操作记录保留";p.shortState = "已接受"
                p.nextStep = plan.part < plan.partCount ? (job.videoContinuationAuthorized ? "可继续准备下一段，无需再次确认本段。" : "本段接受已记录；续段授权尚未明确，没有启动下一段。") : "此镜头的候选接受已记录。"
            } else if job.h3VideoReview != nil {
                p.state = "旧操作记录保留 · 当前接受动作未绑定";p.shortState = "待接受";p.tone = .attention
                p.nextStep = "可在结果页接受当前候选，原操作记录继续保留。"
            } else {
                p.state = "候选已完成 · 等待用户视频验收";p.shortState = "待验收";p.tone = .waiting;p.symbol = "play.rectangle"
                p.nextStep = "在应用结果页接受并继续，也可拒绝候选或重做；无需聊天里重复确认。"
            }
            return p
        }
        return ActivityPresenter.job(job,now:now,automaticLaunchesPaused:state.automaticLaunchesPaused == true)
    }
}
