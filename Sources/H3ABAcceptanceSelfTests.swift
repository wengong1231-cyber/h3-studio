import Foundation

@MainActor enum H3ABAcceptanceSelfTests {
    static func run(store: TaskStore,runtime: H3Runtime,check: (String,Bool,String) throws -> Void) async throws {
        let job = store.state.jobs[0],workspace = store.root,fm = FileManager.default
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        let identity = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime)
        // Reproduce the real pre-automaticCheck format using only this CPU fixture.
        let originalBinding = job.h3Binding!,configURL = URL(fileURLWithPath:originalBinding.appABTask!.configurationPath)
        let nativeURL = URL(fileURLWithPath:originalBinding.jobPath),configBytes = try Data(contentsOf:configURL),nativeBytes = try Data(contentsOf:nativeURL)
        var oldConfig = originalBinding.appABTask!.configuration
        oldConfig.first.automaticCheck = nil;oldConfig.last.automaticCheck = nil
        var oldNative = try JSONDecoder().decode(H3SingleJob.self,from:nativeBytes)
        let oldConfigBytes = try encoder.encode(oldConfig),oldConfigHash = H3ABConfigurationReader.digest(oldConfigBytes)
        oldNative.app_ab_task!.configuration = oldConfig;oldNative.app_ab_task!.configurationSHA256 = oldConfigHash
        oldNative.frozen[configURL.path] = oldConfigHash
        try oldConfigBytes.write(to:configURL);try encoder.encode(oldNative).write(to:nativeURL)
        let strictRejects = rejected { _ = try H3ABTaskBinding.load(nativeURL,runtime:runtime,requireFresh:false) }
        let (historicalBinding,_) = try H3ABTaskBinding.load(nativeURL,runtime:runtime,requireFresh:false,allowHistoricalInputChecks:true)
        var historicalJob = job;historicalJob.h3Binding = historicalBinding;historicalJob.h3ABConfiguration = oldConfig
        let historicalIdentity = try H3ABAcceptanceReader.identity(job:historicalJob,workspace:workspace,runtime:runtime)
        try check("旧A/B缺少自动检查字段仍安全读取",strictRejects && historicalIdentity.clipSHA256 == identity.clipSHA256 && historicalIdentity.nativeJobSHA256 != identity.nativeJobSHA256,"实际重算原图及归一检查，仅兼容两项缺失元数据；历史原生身份独立绑定")
        try check("历史兼容不能用于新执行",rejected { _ = try H3ABTaskBinding.load(nativeURL,runtime:runtime,allowHistoricalInputChecks:true) },"领取路径不允许使用历史兼容")
        let parsed = originalBinding.appABTask!.configuration
        var badOld = oldConfig;badOld.prompt = "changed"
        try check("历史兼容不放松提示词身份",!H3ABTaskBinding.configurationsMatch(parsed,badOld,allowHistoricalInputChecks:true),"除缺失检查字段外所有配置仍须完全一致")
        badOld = oldConfig;badOld.first.automaticCheck = parsed.first.automaticCheck
        try check("局部检查字段异常不兼容",!H3ABTaskBinding.configurationsMatch(parsed,badOld,allowHistoricalInputChecks:true),"不丢弃已有检查或忽略半新半旧记录")
        var badParsed = parsed;badParsed.first.automaticCheck?.width = 1
        try check("历史兼容仍要求新解码通过",!H3ABTaskBinding.configurationsMatch(badParsed,oldConfig,allowHistoricalInputChecks:true),"归一尺寸或检查身份变化不匹配")
        try configBytes.write(to:configURL);try nativeBytes.write(to:nativeURL)
        let instruction = H3ABAcceptanceInstruction(candidate:identity,actorKind:"user",explicitUserAcceptance:true,
            sourceReference:"CPU-only fixture: explicit historical user message",userQuote:"Fixture user explicitly accepted this A/B candidate.")
        try instruction.validate(identity)
        try check("A/B 历史接受独立于队列端点",job.h3QueuePlan == nil && job.h3VideoReview == nil && identity.appJobID == job.id,"真实 CPU73 帧候选与绑定、技术报告全部重核；不虚构队列计划或端点目视检查")
        for (label,edit) in [
            ("助手不得代替用户接受", { (v: inout H3ABAcceptanceInstruction) in v.actorKind = "assistant" }),
            ("缺明确接受不得导入", { (v: inout H3ABAcceptanceInstruction) in v.explicitUserAcceptance = false }),
            ("空白原话不得导入", { (v: inout H3ABAcceptanceInstruction) in v.userQuote = "   " }),
            ("不同任务不得导入", { (v: inout H3ABAcceptanceInstruction) in v.candidate.appJobID = UUID() }),
            ("不同视频不得导入", { (v: inout H3ABAcceptanceInstruction) in v.candidate.clipSHA256 = String(repeating:"0",count:64) }),
            ("不同技术报告不得导入", { (v: inout H3ABAcceptanceInstruction) in v.candidate.reportSHA256 = String(repeating:"0",count:64) }),
            ("历史接受不扩大到续段", { (v: inout H3ABAcceptanceInstruction) in v.scope = "authorize_continuation" })
        ] {
            var changed = instruction;edit(&changed)
            try check(label,rejected { try changed.validate(identity) },"拒绝不匹配的接受指令；未写生产数据")
        }
        var wrong = job;wrong.status = .cancelled
        try check("取消候选不能补记",rejected { _ = try H3ABAcceptanceReader.identity(job:wrong,workspace:workspace,runtime:runtime) },"不覆盖取消状态")
        wrong = job;wrong.supersededBy = UUID()
        try check("重做历史不能补记",rejected { _ = try H3ABAcceptanceReader.identity(job:wrong,workspace:workspace,runtime:runtime) },"不把旧版本重新放行")
        wrong = job;wrong.h3Outcome?.visualReview = "quality_unpassed"
        try check("拒绝状态不能补记",rejected { _ = try H3ABAcceptanceReader.identity(job:wrong,workspace:workspace,runtime:runtime) },"不把质量拒绝覆盖为接受")
        wrong = job;wrong.h3Binding?.jobSHA256 = String(repeating:"0",count:64)
        try check("绑定身份变化不能补记",rejected { _ = try H3ABAcceptanceReader.identity(job:wrong,workspace:workspace,runtime:runtime) },"App缓存也必须等于磁盘完整绑定")
        let source = URL(fileURLWithPath:job.h3ABConfiguration!.first.originalPath!),sourceBytes = try Data(contentsOf:source)
        try Data("tampered fixture input".utf8).write(to:source)
        let sourceRejected = rejected { _ = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime) }
        try sourceBytes.write(to:source)
        try check("冻结原图变化不能补记",sourceRejected,"实际修改隔离原图，绑定读取拒绝；恢复原字节")
        let report = URL(fileURLWithPath:job.h3Outcome!.reportPath),reportBytes = try Data(contentsOf:report)
        var reportJSON = try JSONSerialization.jsonObject(with:reportBytes) as! [String:Any]
        reportJSON["schema"] = "jingsheng-App-S41-native-technical-v1";reportJSON["status"] = "technical_pass_visual_review_pending"
        try JSONSerialization.data(withJSONObject:reportJSON).write(to:report)
        let legacyIdentity = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime)
        try check("旧版与当前A/B技术报告分别核验",legacyIdentity.clipSHA256 == identity.clipSHA256 && legacyIdentity.reportSHA256 != identity.reportSHA256,"支持旧 v1 与当前 v2，通过状态与视频身份仍严格绑定")
        reportJSON["status"] = "failed";try JSONSerialization.data(withJSONObject:reportJSON).write(to:report)
        let failedReportRejected = rejected { _ = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime) }
        try check("失败技术报告不得补记接受",failedReportRejected,"技术报告状态也须通过，不仅检查解码字段")
        reportJSON = try JSONSerialization.jsonObject(with:reportBytes) as! [String:Any];reportJSON["clip_sha256"] = String(repeating:"0",count:64)
        try JSONSerialization.data(withJSONObject:reportJSON).write(to:report)
        let reportRejected = rejected { _ = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime) }
        try reportBytes.write(to:report)
        try check("技术报告绑定变化不能补记",reportRejected,"不凭技术通过布尔缓存接受错误视频")
        let rejectionURL = H3VideoRejectionReader.url(workspace:workspace,id:job.id)
        try fm.createDirectory(at:rejectionURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("existing rejection receipt".utf8).write(to:rejectionURL)
        let rejectionBlocked = rejected { _ = try H3ABAcceptanceReader.identity(job:job,workspace:workspace,runtime:runtime) }
        try fm.removeItem(at:rejectionURL)
        try check("磁盘拒绝回执不能绕过",rejectionBlocked,"即使状态字段尚未刷新也保留拒绝")
        let request = workspace.appendingPathComponent("fixture-acceptance.json");try encoder.encode(instruction).write(to:request)
        let originalJob = try encoder.encode(job),originalCandidateSHA = identity.clipSHA256,launches = store.launchCount
        let unrelated = ShotJob(shot:45,segment:"independent",title:"CPU isolated unrelated task",prompt:"",requestedDuration:1,engine:.fixture,status:.blocked)
        store.state.jobs.append(unrelated)
        let unrelatedBytes = try encoder.encode(unrelated),paused = store.state.queuePaused,automaticPaused = store.state.automaticLaunchesPaused
        try await store.importABAcceptance(request,id:job.id)
        let accepted = store.state.jobs[0].h3ABAcceptance!
        try check("历史接受保存完整前状态",try Data(contentsOf:URL(fileURLWithPath:accepted.receipt.previousJobPath)) == originalJob,"补记前完整任务含原 outcome、尝试和绑定，未覆盖旧技术报告")
        try check("历史接受只更新同一任务",store.state.jobs.count == 2 && store.state.jobs[0].id == job.id && (try encoder.encode(store.state.jobs[1])) == unrelatedBytes && store.launchCount == launches && store.state.queuePaused == paused && store.state.automaticLaunchesPaused == automaticPaused,"ID、独立任务、暂停和生成次数保持")
        try check("历史接受不伪造队列或成片",store.state.jobs[0].h3Outcome?.visualReview == "accepted_existing_user_instruction" && store.state.jobs[0].h3Outcome?.selectedForProduction == false && store.state.jobs[0].h3QueuePlan == nil && store.state.jobs[0].h3VideoReview == nil && !store.state.jobs[0].videoContinuationAuthorized,"独立 A/B 来源记录不授予端帧接续或选入 MV")
        try check("A/B接受状态与来源可见",store.state.jobs[0].displayStatusLabel == "已接受 · 既有用户指令" && accepted.receipt.instruction.userQuote == instruction.userQuote,"原话、来源和候选指纹可供界面查看")
        let stateBeforeRepeat = try encoder.encode(store.state.jobs[0])
        try await store.importABAcceptance(request,id:job.id)
        try check("重复接受导入幂等",try encoder.encode(store.state.jobs[0]) == stateBeforeRepeat,"不重建审计、不改时间、不增日志或任务")
        var otherSource = instruction;otherSource.sourceReference += " changed";try encoder.encode(otherSource).write(to:request)
        var conflictRejected = false;do { try await store.importABAcceptance(request,id:job.id) } catch { conflictRejected = true }
        try check("不同来源不能覆盖已存接受",conflictRejected && (try encoder.encode(store.state.jobs[0])) == stateBeforeRepeat,"冲突保留原回执和当前状态")
        let loaded = try H3ABAcceptanceReader.load(job:store.state.jobs[0],workspace:workspace,runtime:runtime)
        try check("接受回执可完整重验",loaded == accepted && (try WorkspaceDigest.sha256(URL(fileURLWithPath:job.candidate!))) == originalCandidateSHA && (try Data(contentsOf:report)) == reportBytes,"视频与原技术报告逐字节保持")
        let frozenURL = URL(fileURLWithPath:accepted.receipt.instructionPath),frozenData = try Data(contentsOf:frozenURL)
        try encoder.encode(otherSource).write(to:frozenURL)
        let frozenRejected = rejected { _ = try H3ABAcceptanceReader.load(job:store.state.jobs[0],workspace:workspace,runtime:runtime) }
        try frozenData.write(to:frozenURL)
        try check("原话档案篡改会失效",frozenRejected,"重读回执校验来源文件哈希而不信任缓存")
        store.state.jobs.removeLast();store.persist()
    }
}
