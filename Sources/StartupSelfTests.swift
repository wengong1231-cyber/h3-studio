import Foundation
import Combine
import Darwin

@MainActor enum StartupSelfTests {
    private static func fixture(_ root: URL, age: Double = 0, downloading: Bool = false) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("models/mock-only")
        try Data(repeating: 1, count: 10).write(to: fileURL)
        var identity: [String: Any] = ["relative_path":"mock-only", "remote_path":"mock-only", "repo":"fixture", "revision":String(repeating:"a", count:40), "sha256":try WorkspaceDigest.sha256(fileURL), "size":10]
        let manifest: [String: Any] = ["version":1, "model_dir":root.appendingPathComponent("models").path, "total_bytes":10, "original_quantized_model_key":ModelValidationContext.modelKey, "lora_key":ModelValidationContext.loraKey, "files":[identity]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("download-manifest.json"))
        identity["state"] = "verified"; identity["downloaded_bytes"] = 10; identity["publisher_checksum_verified"] = true
        let status: [String: Any] = ["version":1, "model_dir":root.appendingPathComponent("models").path, "status":downloading ? "running" : "completed", "updated_at":ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age)), "downloaded_bytes":10, "expected_bytes":10, "verified_files":1, "total_files":1, "quantization_still_required":false, "generation_started":false, "files":[identity]]
        try JSONSerialization.data(withJSONObject: status).write(to: root.appendingPathComponent("download-status.json"))
    }
    private static func locations(_ root: URL) -> ExternalLocations { ExternalLocations(originalProject: root.path, modelStatusRoot: root.path, ffmpeg: root.appendingPathComponent("unused").path) }
    static func hungExitProfile(root: URL, executable: URL) async -> Int32 {
        do {
            let service = ModelStatusReadService { _ in DispatchSemaphore(value: 0).wait(); return .failure(.unavailable) }
            let store = try TaskStore(root: root, executable: executable, monitoring: true, locations: locations(root), modelStatusService: service, modelStatusTimeout: 0.1)
            store.startBackgroundStatus()
            try await StudioSelfTests.wait("hung read timeout") { store.readiness.phase == .timedOut }
            let before = ProcessInfo.processInfo.systemUptime
            let step = StudioQuitFlow().request(store: store)
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            let result: [String: Any] = ["quitFlowTerminatesImmediately":step == .terminateNow, "shutdownSeconds":elapsed, "readerStillBlocked":service.isBusy, "acceptedReads":service.acceptedReadCount, "nativeGUIStarted":false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: root.appendingPathComponent("hung-exit-report.json"))
            return step == .terminateNow && elapsed < 0.1 && service.isBusy && service.acceptedReadCount == 1 ? 0 : 1
        } catch { return 1 }
    }
    static func run(root: URL, executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        var metrics: [String: Double] = [:]
        func check(_ name: String, _ value: Bool, _ detail: String) throws {
            checks.append(.init(name: name, passed: value, detail: detail))
            FileHandle.standardOutput.write(Data("\(value ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !value { throw StudioError.invalid(name) }
        }
        do {
            guard !FileManager.default.fileExists(atPath: root.path) else { throw StudioError.invalid("Startup test root must be new") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let inputs = root.appendingPathComponent("inputs"); try fixture(inputs)
            let slowService = ModelStatusReadService { url in Thread.sleep(forTimeInterval: 0.8); return ModelStatusReader.read(url) }
            let initial = ProcessInfo.processInfo.systemUptime
            let store = try TaskStore(root: root.appendingPathComponent("workspace"), executable: executable, monitoring: true, locations: locations(inputs), modelStatusService: slowService, modelStatusTimeout: 0.12)
            metrics["storeInitializationSeconds"] = ProcessInfo.processInfo.systemUptime - initial
            try check("工作区和窗口所需状态不等待外部读取", metrics["storeInitializationSeconds"]! < 0.2 && slowService.acceptedReadCount == 0 && store.state.queuePaused && store.readiness.phase == .idle, "实际 TaskStore 完成状态/锁/观察对象初始化；GUI 未启动，delegate 在窗口展示后才开始读取")
            store.add(ShotJob(shot: 15, segment: "s15-p01", title: "未绑定真实任务", prompt: "fixture-only", requestedDuration: 124.0 / 24.0, engine: .h3, status: .blocked))
            var publicationsOnMain = true
            let subscription = store.readiness.objectWillChange.sink { _ in publicationsOnMain = publicationsOnMain && Thread.isMainThread }
            let start = ProcessInfo.processInfo.systemUptime
            store.startBackgroundStatus()
            metrics["readStartReturnSeconds"] = ProcessInfo.processInfo.systemUptime - start
            try check("800ms 读取启动立即返回", metrics["readStartReturnSeconds"]! < 0.1 && slowService.acceptedReadCount == 1, "读取在 utility 串行队列，主 actor 不运行 Data/open")
            let heartStart = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: 50_000_000)
            metrics["slowReadHeartbeatSeconds"] = ProcessInfo.processInfo.systemUptime - heartStart
            try check("慢读取期间主 actor 心跳正常", metrics["slowReadHeartbeatSeconds"]! < 0.2 && slowService.isBusy, "50ms 心跳恢复，而实际800ms读取仍在进行")
            try await StudioSelfTests.wait("visible read timeout") { store.readiness.phase == .timedOut }
            try check("读取超时可见且不假就绪", store.readiness.reportLabel.contains("超时") && !store.readiness.hasConfirmedCurrentSnapshot && store.readiness.snapshot == nil && store.activeJob == nil && !store.canStart, "超时不释放读取槽位、不启用未绑定H3任务")
            for _ in 0..<300 { store.readiness.refresh(); store.readiness.start() }
            try check("重复刷新和开始保持 single-flight", slowService.acceptedReadCount == 1 && slowService.isBusy, "300轮请求没有排队叠加读取或创建更多读线程")
            try await StudioSelfTests.wait("slow read eventual completion") { store.readiness.phase == .ready }
            try check("迟到成功可恢复且主线程发布", publicationsOnMain && store.readiness.snapshot?.downloaded_bytes == 10 && store.readiness.hasConfirmedCurrentSnapshot && store.activeJob == nil, "后台结果仅MainActor发布；模型快照不启动真实任务")
            subscription.cancel()
            let refreshService = ModelStatusReadService { url in Thread.sleep(forTimeInterval:0.15);return ModelStatusReader.read(url) }
            let refreshMonitor = ModelReadinessMonitor(root:inputs,service:refreshService,timeout:1,pollInterval:30)
            refreshMonitor.start();try await StudioSelfTests.wait("initial stable display") { refreshMonitor.phase == .ready }
            let stableLabel = refreshMonitor.reportLabel
            refreshMonitor.refresh()
            try check("短轮询保留已核验模型文案",refreshMonitor.phase == .reading && refreshMonitor.presentationPhase == .ready && refreshMonitor.reportLabel == stableLabel && !refreshMonitor.hasConfirmedCurrentSnapshot,"显示保持稳定；实际启动判断仍要求当前读取完成")
            try await StudioSelfTests.wait("stable refresh complete") { refreshMonitor.phase == .ready }
            refreshMonitor.stop()
            let idleFocus = store.executionFocus()
            var idleControlRefreshes = 0
            let controlUpdates = store.objectWillChange.sink { idleControlRefreshes += 1 }
            store.historyImportInFlight = true
            try check("短历史轮询不切换当前下一项",store.executionFocus().globalWait == idleFocus.globalWait && !store.backgroundReadVisible(),"只读占用仍阻止实际启动；短读取不引起视图内容闪动")
            store.historyReadStartedAt = Date().addingTimeInterval(-2)
            try check("慢后台读取仍清晰显示",store.backgroundReadVisible() && store.executionFocus().globalWait != nil,"持续读取超过一秒再显示，超时仍保留诊断")
            store.historyImportInFlight = false
            try check("空闲读取结束刷新按钮且开始不闪动",idleControlRefreshes == 1,"finishing a short read republishes available actions even when no job or banner changed")
            store.videoReviewRefreshInFlight = true;store.videoReviewRefreshInFlight = false
            try check("验收轮询结束恢复可用操作",idleControlRefreshes == 2,"background state is not presented as a transient foreground task")
            controlUpdates.cancel()
            let staleInputs = root.appendingPathComponent("stale-inputs"); try fixture(staleInputs, age: 100, downloading: true)
            let stale = ModelReadinessMonitor(root: staleInputs, service: ModelStatusReadService())
            stale.start(); try await StudioSelfTests.wait("stale source") { stale.phase == .ready }
            try check("进行中100%字节仍需要下载心跳", stale.fraction == 1 && !stale.hasConfirmedCurrentSnapshot && stale.reportLabel == "下载心跳待更新", "尚未进入已校验终态；超过45秒明确陈旧")
            stale.stop()
            let cancelledService = ModelStatusReadService { url in Thread.sleep(forTimeInterval: 0.25); return ModelStatusReader.read(url) }
            let cancelled = ModelReadinessMonitor(root: inputs, service: cancelledService, timeout: 0.1)
            cancelled.start(); cancelled.stop()
            try await Task.sleep(nanoseconds: 350_000_000)
            try check("停止后不发布迟到结果", cancelled.snapshot == nil && cancelled.phase == .stopped && cancelledService.acceptedReadCount == 1, "stop不等待读返回，旧generation不能更新已停止的UI")
            let failing = ModelReadinessMonitor(root: inputs, service: ModelStatusReadService { _ in .failure(.unavailable) })
            failing.start(); try await StudioSelfTests.wait("missing source") { failing.phase == .unavailable }
            try check("读取错误不泄露来源内容", failing.error?.contains(inputs.path) == false && !failing.hasConfirmedCurrentSnapshot, "只发布固定错误口径，无路径或文件内容")
            failing.stop()
            let unsafe = root.appendingPathComponent("unsafe"); try fixture(unsafe)
            let manifest = unsafe.appendingPathComponent("download-manifest.json")
            try FileManager.default.removeItem(at: manifest); _ = mkfifo(manifest.path, S_IRUSR | S_IWUSR)
            let unsafeMonitor = ModelReadinessMonitor(root: unsafe, service: ModelStatusReadService())
            unsafeMonitor.start(); try await StudioSelfTests.wait("unsafe file rejection") { unsafeMonitor.phase == .unavailable }
            try check("后台拒绝非普通状态文件", unsafeMonitor.snapshot == nil && unsafeMonitor.error?.contains("普通") == true, "在后台检查文件类型，FIFO无需等待writer")
            unsafeMonitor.stop()
            store.shutdown()
            try await StudioSelfTests.wait("privacy phase log") { FileManager.default.fileExists(atPath: store.root.appendingPathComponent("startup-phases.jsonl").path) }
            try await Task.sleep(nanoseconds: 50_000_000)
            let logData = try Data(contentsOf: store.root.appendingPathComponent("startup-phases.jsonl"))
            let logText = String(decoding: logData, as: UTF8.self)
            let rows = try logText.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            try check("阶段日志只含时间版本固定事件", rows.count > 2 && rows.allSatisfy { Set($0.keys) == ["date","version","phase"] } && !logText.contains(root.path) && !logText.contains("fixture-only"), "后台有界写入；不记录路径、prompt、任务ID或错误内容")
            let childRoot = root.appendingPathComponent("hung-exit")
            let child = Process(); child.executableURL = executable; child.arguments = ["--startup-hung-exit-profile", childRoot.path]
            child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); let childBegin = ProcessInfo.processInfo.systemUptime
            try await StudioSelfTests.wait("normal exit with never-returning reader", timeout: 4) { !child.isRunning }
            metrics["hungReaderChildExitSeconds"] = ProcessInfo.processInfo.systemUptime - childBegin
            let childReport = try JSONSerialization.jsonObject(with: Data(contentsOf: childRoot.appendingPathComponent("hung-exit-report.json"))) as! [String: Any]
            try check("永久挂起读不阻止正常退出", child.terminationStatus == 0 && childReport["quitFlowTerminatesImmediately"] as? Bool == true && childReport["readerStillBlocked"] as? Bool == true && metrics["hungReaderChildExitSeconds"]! < 3, "真实独立CPU profile 经生产QuitFlow/shutdown自然exit0；未发送kill或启动GUI")
            let foreverService = ModelStatusReadService { _ in DispatchSemaphore(value: 0).wait(); return .failure(.unavailable) }
            let forever = ModelReadinessMonitor(root: inputs, service: foreverService, timeout: 0.1, pollInterval: 0.05)
            let another = ModelReadinessMonitor(root: inputs, service: foreverService, timeout: 0.1, pollInterval: 0.05)
            forever.start(); another.start()
            try await StudioSelfTests.wait("never return visible timeout") { forever.phase == .timedOut && another.phase == .timedOut }
            for _ in 0..<500 { forever.refresh(); forever.stop(); forever.start(); another.refresh() }
            try await Task.sleep(nanoseconds: 50_000_000)
            try check("永久挂起跨监控实例仍只有一读", foreverService.acceptedReadCount == 1 && foreverService.isBusy && forever.snapshot == nil && another.snapshot == nil, "共享service槽位不会因timeout/stop/start释放；500轮无叠加任务")
            let stopBegin = ProcessInfo.processInfo.systemUptime; forever.stop(); another.stop()
            metrics["hungMonitorStopSeconds"] = ProcessInfo.processInfo.systemUptime - stopBegin
            try check("关闭监控不等待永久挂起读", metrics["hungMonitorStopSeconds"]! < 0.1 && forever.phase == .stopped && foreverService.isBusy, "只关闭轮询和发布，不await后台open或无限重试")
            let result: [String: Any] = ["date":ISO8601DateFormatter().string(from: Date()), "passed":true, "checks":checks.map { ["name":$0.name,"passed":$0.passed,"detail":$0.detail] }, "metrics":metrics, "nativeGUIStarted":false, "productionStateTouched":false, "installedAppTouched":false, "realModelFilesRead":false, "realGPUStarted":false, "scope":"Headless actual TaskStore/ModelReadiness/QuitFlow; window creation remains formal CUA acceptance"]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("startup-test-report.json"))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Startup regression failed: \(error.localizedDescription)\n".utf8))
            if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("startup-test-report.json")) }
            return 1
        }
    }
}
