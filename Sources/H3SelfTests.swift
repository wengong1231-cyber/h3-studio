import Foundation
import Darwin

@MainActor enum H3SelfTests {
    struct Check: Codable { var name: String; var passed: Bool; var detail: String }
    private static var harnessStore: TaskStore?
    static func crashHarness(root: URL, executable: URL) async {
        do {
            let runtime = H3Runtime.mock(root: root.appendingPathComponent("runtime"), executable: executable)
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as! [String: String]
            let store = try TaskStore(root: root.appendingPathComponent("workspace"), executable: executable, monitoring: false, h3Runtime: runtime)
            harnessStore = store
            let id = try store.importH3Job(URL(fileURLWithPath: config["jobPath"]!)); let binding = store.state.jobs[0].h3Binding!
            store.startH3(id, approval: .mockForTests(binding.jobSHA256))
            try await StudioSelfTests.wait("mock crash harness native progress") { store.activeJob?.progress?.completed ?? 0 > 0 }
            let status = try JSONSerialization.jsonObject(with: H3Files.read(binding.nativeStatus)) as! [String: Any]
            let pids = [store.activeJob?.workerPID, (status["controller_pid"] as? NSNumber)?.int32Value, (status["vpipe_pid"] as? NSNumber)?.int32Value].compactMap { $0 }
            try JSONEncoder().encode(pids.compactMap(ProcessIdentity.capture)).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        } catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
    }
    static func run(root: URL, executable: URL) async -> Int32 {
        let fm = FileManager.default; var checks: [Check] = []
        func check(_ name: String, _ value: Bool, _ detail: String) throws {
            checks.append(Check(name: name, passed: value, detail: detail)); FileHandle.standardOutput.write(Data("\(value ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !value { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func mutate(_ file: URL, _ edit: (inout [String: Any]) -> Void) throws {
            var object = try JSONSerialization.jsonObject(with: H3Files.read(file)) as! [String: Any]; edit(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }
        func environment(_ name: String) throws -> (TaskStore, H3Runtime, URL) {
            let base = root.appendingPathComponent(name, isDirectory: true)
            let runtime = try H3Mock.createRuntime(root: base.appendingPathComponent("runtime"), executable: executable)
            let store = try TaskStore(root: base.appendingPathComponent("workspace"), executable: executable, monitoring: false, h3Runtime: runtime)
            return (store, runtime, base)
        }
        do {
            guard !fm.fileExists(atPath: root.path) else { throw StudioError.invalid("H3 mock 测试必须使用新的隔离目录。") }
            _ = try H3Files.safe(root.path); try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let native = H3Progress.event("[PROGRESS] 10% of 'denoise' completed at 00:00:00 (20/200)")
            let optimized = H3Progress.event("[PROGRESS] 33% of 'denoise' completed at 00:00:01 (50/150)")
            let end = H3Progress.event("[PROGRESS] 'denoise' ended at 00:00:02, last reported 98% (148/150)")
            try check("真实分母调整按原生计数解析", native?.completed == 20 && native?.total == 200 && optimized?.completed == 50 && optimized?.total == 150 && optimized?.unit == "阶段单位", "固定请求 4 步不替代原生日志的 200→150 分母")
            try check("阶段结束不补造百分比", end?.type == "stage" && end?.completed == nil && end?.total == nil && H3Progress.event("[PROGRESS] unknown native stage")?.type == "stage", "98% ended 或未知进度均返回不确定阶段，不能当整体完成")
            let assembler = H3LineAssembler(), utf8 = Data("[STAGE] 载入模型\r\nlast-no-newline".utf8)
            let split = 10
            let parsed = assembler.append(utf8.prefix(split)) + assembler.append(utf8.dropFirst(split)) + assembler.finish()
            try check("增量日志支持 UTF-8 与末行", parsed == ["[STAGE] 载入模型", "last-no-newline"], "按字节保存跨块汉字，CRLF 只形成一行，EOF 残行保留")
            let (store, runtime, _) = try environment("normal")
            let firstPath = try H3Mock.createJob(runtime: runtime), secondPath = try H3Mock.createJob(runtime: runtime)
            let first = try store.importH3Job(firstPath), duplicate = try store.importH3Job(firstPath), second = try store.importH3Job(secondPath)
            try check("单镜导入不启动且稳定去重", first == duplicate && store.state.jobs.count == 2 && store.launchCount == 0 && store.state.queuePaused, "导入已授权新 job，仅保存记录，不准备新管线或自动投递")
            store.startQueue(); try check("普通队列不会启动 H3", store.launchCount == 0 && store.activeJob == nil && !store.canStart, "开始队列仅启动 CPU fixture，H3 必须单镜确认")
            let binding = store.state.jobs[0].h3Binding!
            store.startH3(first, approval: .mockForTests("wrong fingerprint"))
            try check("确认绑定变化不领取任务", store.launchCount == 0 && !fm.fileExists(atPath: store.root.appendingPathComponent("h3-dispatch/\(binding.jobSHA256).json").path), "无有效确认指纹时未创建投递记录或进程")
            store.startH3(first, approval: .mockForTests(binding.jobSHA256)); store.startH3(first, approval: .mockForTests(binding.jobSHA256))
            store.startH3(second, approval: .mockForTests(store.state.jobs[1].h3Binding!.jobSHA256))
            try check("重复点击与并发单镜被拒绝", store.launchCount == 1 && store.activeJob?.id == first && store.state.jobs[1].status == .blocked && store.state.queuePaused, "只拥有一个 supervisor，另一单镜不启动")
            let receipt = try JSONDecoder().decode(H3DispatchReceipt.self, from: H3Files.read(store.root.appendingPathComponent("h3-dispatch/\(binding.jobSHA256).json")))
            try check("进程启动前持久领取", receipt.jobSHA256 == binding.jobSHA256 && receipt.appJobID == first && receipt.supervisor?.pid == store.activeJob?.workerPID, "单次投递日志绑定任务、session、PID 与启动时间")
            try check("H3 监控最低十秒", store.telemetry.interval >= 10, "保留用户采样偏好，单镜运行期间最低十秒，不伪装 GPU 数值")
            try await StudioSelfTests.wait("mock native actual frame progress") { store.activeJob?.progress?.completed ?? 0 > 0 }
            try check("原生日志驱动实际阶段进度", store.activeJob?.progress?.total == 48 && store.activeJob?.progress?.unit == "阶段单位", "mock 计数由实际写出的 CPU 帧事件转为原生日志，非计时百分比")
            store.consume(String(decoding: try JSONEncoder().encode(EngineEvent(type: "stage", stage: "未知原生阶段")), as: UTF8.self), stderr: false, jobID: first, attemptNumber: 1)
            try check("未知阶段清除前阶段进度", store.activeJob?.progress == nil && store.activeJob?.stage == "未知原生阶段", "分阶段进度不泄漏到下一阶段")
            try await StudioSelfTests.wait("mock strict validation completed", timeout: 12) { store.activeJob == nil }
            try check("成功必须经过严格验证适配", store.state.jobs[0].status == .completed && store.state.jobs[0].h3Outcome?.technicalPass == true && store.state.jobs[0].h3Outcome?.simulated == true && store.state.jobs[0].h3Outcome?.selectedForProduction == false && store.state.jobs[0].h3Outcome?.visualReview == "not_automatically_evaluated", "CPU mock 严格解码通过仍非真实 H3，也不自动通过人工审查或选入成片")
            try check("候选路径绑定独立单镜", store.state.jobs[0].candidate == binding.clipPath && !binding.clipPath.hasPrefix(store.state.jobs[0].attempts[0].directory) && fm.fileExists(atPath: binding.clipPath), "native 输出在核准 work/candidates，App 日志在自有 attempt；不改生产路径")
            try check("成功后下一镜仍待确认", store.launchCount == 1 && store.state.jobs[1].status == .blocked && store.state.queuePaused, "no_auto_queue 契约始终保留")
            try check("已领取单镜不再导入", rejected { _ = try store.importH3Job(firstPath) }, "外部 attempt/status 与 App 投递记录均阻止重复提交")

            let (policy, policyRuntime, _) = try environment("policies")
            let denied = try H3Mock.createJob(runtime: policyRuntime)
            try mutate(denied) { value in var auth = value["authorization"] as! [String: Any]; auth["user_authorized"] = false; value["authorization"] = auth }
            try check("拒绝未授权单镜", rejected { _ = try policy.importH3Job(denied) } && policy.launchCount == 0, "不把待授权提案自动变为真实任务")
            let wrongProfile = try H3Mock.createJob(runtime: policyRuntime)
            try mutate(wrongProfile) { value in var profile = value["profile"] as! [String: Any]; profile["frames"] = 72; value["profile"] = profile }
            try check("拒绝契约外镜头配置", rejected { _ = try policy.importH3Job(wrongProfile) }, "只接 v2 的 S15 / 124 帧 / 固定模型与资源上限")
            let occupied = try H3Mock.createJob(runtime: policyRuntime)
            try Data("claimed fixture".utf8).write(to: occupied.deletingLastPathComponent().appendingPathComponent("attempt-once.json"))
            try check("已有领取标记不能重跑", rejected { _ = try policy.importH3Job(occupied) }, "不删除旧 claim、不复制旧首镜重新提交")
            let previous = try H3Mock.createJob(runtime: policyRuntime), clone = try H3Mock.createJob(runtime: policyRuntime)
            let previousObject = try JSONSerialization.jsonObject(with: H3Files.read(previous)) as! [String: Any]
            try mutate(URL(fileURLWithPath: policyRuntime.contractPath)) { value in var observed = value["observed_candidate"] as! [String: Any]; observed["job"] = previous.path; value["observed_candidate"] = observed }
            try mutate(clone) { $0["job_id"] = previousObject["job_id"] }
            try check("已领取首镜换路径仍被拒绝", rejected { _ = try policy.importH3Job(clone) }, "同时核对原身份与路径，不靠改目录绕过首镜禁重投")
            let escape = try H3Mock.createJob(runtime: policyRuntime)
            try mutate(escape) { $0["clip_path"] = root.appendingPathComponent("outside.mp4").path }
            try check("输出逃出绑定目录被拒绝", rejected { _ = try policy.importH3Job(escape) }, "不允许原工程成片或另一个任务的路径成为本次输出")
            let changed = try H3Mock.createJob(runtime: policyRuntime), changedID = try policy.importH3Job(changed)
            let changedBinding = policy.state.jobs.last!.h3Binding!
            try mutate(changed) { $0["seed"] = 2 }
            policy.startH3(changedID, approval: .mockForTests(changedBinding.jobSHA256))
            try check("投递前再次校验任务指纹", policy.launchCount == 0 && !fm.fileExists(atPath: policy.root.appendingPathComponent("h3-dispatch/\(changedBinding.jobSHA256).json").path), "确认后文件变化立即阻止，不执行 stale job")
            let gate = try H3Mock.createJob(runtime: policyRuntime)
            try mutate(URL(fileURLWithPath: policyRuntime.contractPath)) { $0["next_generation_authorized"] = false }
            let gatedID = try policy.importH3Job(gate)
            try check("下一次生成授权门槛保留", !policy.canRunH3(gatedID) && policy.state.jobs.last?.h3Binding?.executionAuthorized == false, "v2 当前真实 next_generation_authorized=false 不能被 UI 确认绕过")

            for scenario in ["runner_failure", "missing_output", "validation_failure", "report_mismatch"] {
                let (failure, failureRuntime, _) = try environment(scenario), path = try H3Mock.createJob(runtime: failureRuntime, scenario: scenario)
                let id = try failure.importH3Job(path); let value = failure.state.jobs[0].h3Binding!
                failure.startH3(id, approval: .mockForTests(value.jobSHA256))
                try await StudioSelfTests.wait("H3 mock \(scenario)", timeout: 12) { failure.activeJob == nil }
                failure.retry(id); failure.startH3(id, approval: .mockForTests(value.jobSHA256)); failure.startQueue()
                try check("故障不自动重试：\(scenario)", failure.state.jobs[0].status == .failed && failure.state.jobs[0].h3Outcome == nil && failure.launchCount == 1 && failure.state.queuePaused && !failure.canRunH3(id), "日志与部分产物保留；退出0/视频存在不足以接受，H3 重试需新授权任务")
            }
            let (cancel, cancelRuntime, _) = try environment("cancel"), cancelPath = try H3Mock.createJob(runtime: cancelRuntime, scenario: "cancel_after_output")
            let cancelID = try cancel.importH3Job(cancelPath), cancelBinding = cancel.state.jobs[0].h3Binding!
            let sentinel = Process(); sentinel.executableURL = URL(fileURLWithPath: "/bin/cat"); sentinel.standardInput = Pipe(); sentinel.standardOutput = FileHandle.nullDevice; sentinel.standardError = FileHandle.nullDevice
            try sentinel.run(); defer { if sentinel.isRunning { sentinel.terminate() } }
            var reused = ProcessIdentity.capture(sentinel.processIdentifier)!; reused.startedSeconds += 1; reused.signal(SIGTERM)
            try check("PID 复用身份不能被信号命中", !reused.stillSameProcess && sentinel.isRunning, "启动时间不同不发送 SIGTERM，不靠 PID 数字判断所有权")
            cancel.startH3(cancelID, approval: .mockForTests(cancelBinding.jobSHA256))
            try await StudioSelfTests.wait("mock partial candidate", timeout: 12) { fm.fileExists(atPath: cancelBinding.clipPath) }
            let videoSHA = try WorkspaceDigest.sha256(URL(fileURLWithPath: cancelBinding.clipPath))
            cancel.cancel(cancelID); cancel.cancel(cancelID)
            try await StudioSelfTests.wait("mock cancel owned subtree", timeout: 12) { cancel.activeJob == nil }
            try check("取消保留候选且不影响独立进程", cancel.state.jobs[0].status == .cancelled && cancel.state.jobs[0].h3Outcome == nil && sentinel.isRunning && (try WorkspaceDigest.sha256(URL(fileURLWithPath: cancelBinding.clipPath))) == videoSHA && cancel.launchCount == 1, "实际停止自有 supervisor/controller/native，重复取消幂等；视频未删除")
            let (validatorCancel, validatorRuntime, _) = try environment("cancel-validator"), validatorPath = try H3Mock.createJob(runtime: validatorRuntime, scenario: "slow_validation")
            let validatorID = try validatorCancel.importH3Job(validatorPath)
            validatorCancel.startH3(validatorID, approval: .mockForTests(validatorCancel.state.jobs[0].h3Binding!.jobSHA256))
            try await StudioSelfTests.wait("strict validator phase", timeout: 12) { validatorCancel.activeJob?.stage.contains("严格验证") == true }
            validatorCancel.cancel(validatorID)
            try await StudioSelfTests.wait("validator cancellation", timeout: 12) { validatorCancel.activeJob == nil }
            try check("严格验证阶段也可安全取消", validatorCancel.state.jobs[0].status == .cancelled && validatorCancel.state.jobs[0].h3Outcome == nil && validatorCancel.state.jobs[0].candidate != nil && sentinel.isRunning, "只结束自有验证过程，候选引用仍保留，不把 native exit0 当完成")
            let (stubborn, stubbornRuntime, _) = try environment("stubborn"), stubbornPath = try H3Mock.createJob(runtime: stubbornRuntime, scenario: "stubborn_controller")
            let stubbornID = try stubborn.importH3Job(stubbornPath)
            stubborn.startH3(stubbornID, approval: .mockForTests(stubborn.state.jobs[0].h3Binding!.jobSHA256))
            try await StudioSelfTests.wait("stubborn owned controller") { stubborn.activeJob?.progress?.completed ?? 0 > 0 }
            stubborn.cancel(stubbornID)
            try await StudioSelfTests.wait("stubborn escalation to owned SIGKILL", timeout: 12) { stubborn.activeJob == nil }
            try check("不响应 TERM 的自有进程可结束", stubborn.state.jobs[0].status == .cancelled && stubborn.launchCount == 1 && sentinel.isRunning, "mock 实际忽略 TERM，监督器按原身份升级停止；独立进程保持运行")
            let boundaryBase = root.appendingPathComponent("reservation-boundary"), boundaryRuntime = try H3Mock.createRuntime(root: boundaryBase.appendingPathComponent("runtime"), executable: executable)
            let boundaryPath = try H3Mock.createJob(runtime: boundaryRuntime), workspace = boundaryBase.appendingPathComponent("workspace")
            var boundaryStore: TaskStore? = try TaskStore(root: workspace, executable: executable, monitoring: false, h3Runtime: boundaryRuntime)
            let boundaryID = try boundaryStore!.importH3Job(boundaryPath), boundaryBinding = boundaryStore!.state.jobs[0].h3Binding!
            try fm.createDirectory(at: workspace.appendingPathComponent("h3-dispatch"), withIntermediateDirectories: true)
            let reservation = H3DispatchReceipt(jobSHA256: boundaryBinding.jobSHA256, nativeJobID: boundaryBinding.nativeJobID, appJobID: boundaryID, sessionID: boundaryStore!.sessionID)
            try JSONEncoder().encode(reservation).write(to: workspace.appendingPathComponent("h3-dispatch/\(boundaryBinding.jobSHA256).json")); boundaryStore = nil
            let resumedBoundary = try TaskStore(root: workspace, executable: executable, monitoring: false, h3Runtime: boundaryRuntime)
            resumedBoundary.startH3(boundaryID, approval: .mockForTests(boundaryBinding.jobSHA256))
            try check("领取与创建进程之间中断不重复投递", resumedBoundary.state.jobs[0].status == .interrupted && resumedBoundary.launchCount == 0 && !resumedBoundary.canRunH3(boundaryID), "即使 state 仍是待运行，独立持久 ledger 也阻止重新提交")

            let crash = root.appendingPathComponent("crash", isDirectory: true), crashRuntime = try H3Mock.createRuntime(root: crash.appendingPathComponent("runtime"), executable: executable)
            let crashPath = try H3Mock.createJob(runtime: crashRuntime, scenario: "orphan")
            try JSONSerialization.data(withJSONObject: ["jobPath": crashPath.path]).write(to: crash.appendingPathComponent("config.json"))
            let harness = Process(); harness.executableURL = executable; harness.arguments = ["--h3-crash-harness", crash.path]; harness.standardOutput = FileHandle.nullDevice; harness.standardError = FileHandle.nullDevice
            try harness.run(); defer { if harness.isRunning { harness.terminate() } }
            try await StudioSelfTests.wait("H3 crash harness ready", timeout: 12) { fm.fileExists(atPath: crash.appendingPathComponent("ready.json").path) }
            let owned = try JSONDecoder().decode([ProcessIdentity].self, from: H3Files.read(crash.appendingPathComponent("ready.json")))
            kill(harness.processIdentifier, SIGKILL); harness.waitUntilExit()
            let reopened = try TaskStore(root: crash.appendingPathComponent("workspace"), executable: executable, monitoring: false, h3Runtime: crashRuntime)
            reopened.startQueue(); reopened.retry(reopened.state.jobs[0].id)
            try check("App 崩溃重开不重投单镜", reopened.state.jobs[0].status == .interrupted && reopened.state.queuePaused && reopened.launchCount == 0 && !reopened.canRunH3(reopened.state.jobs[0].id), "实际 SIGKILL 自有 harness，旧任务保持中断；不恢复旧92段")
            try await StudioSelfTests.wait("H3 orphan supervisor cleanup", timeout: 12) { owned.allSatisfy { !$0.stillSameProcess } }
            try check("父进程崩溃关闭管道仍清理自有进程", owned.count == 3 && owned.allSatisfy { !$0.stillSameProcess } && sentinel.isRunning, "supervisor 忽略 SIGPIPE 并处理 owner 失效，自有 controller/native 全部结束")
            let report: [String: Any] = ["passed": true, "checks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(checks)), "testRoot": root.path,
                "realH3Launched": false, "realGPUStarted": false, "nativeUIExecuted": false, "old92SegmentQueueTouched": false,
                "mockModel": "CPU fixture / H3 protocol mock", "date": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("h3-test-report.json"))
            return 0
        } catch {
            checks.append(Check(name: "unexpected error", passed: false, detail: error.localizedDescription))
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("h3-test-report.json")) }
            return 1
        }
    }
}
