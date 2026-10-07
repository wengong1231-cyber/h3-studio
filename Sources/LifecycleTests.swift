import AppKit

@MainActor enum StudioLifecycleTests {
    private static func nativeChecks(executable: URL, check: (String, Bool, String) throws -> Void) throws -> (NSApplication, StudioAppDelegate, NSWindow, NSPanel) {
        // Test only hidden windows belonging to this harness; no activation or desktop input.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = StudioPresentation.mainWindow()
        let panel = StudioPresentation.orbWindow()
        try check("主窗口恢复标准可见标题栏", window.styleMask.contains(.titled) && !window.styleMask.contains(.fullSizeContentView) && window.titleVisibility == .visible && !window.titlebarAppearsTransparent && window.toolbar == nil, "AppKit 隐藏窗口实例检查；不等同于桌面点击验收")
        let close = window.standardWindowButton(.closeButton)
        let mini = window.standardWindowButton(.miniaturizeButton)
        let zoom = window.standardWindowButton(.zoomButton)
        try check("主窗口标准红黄绿按钮可用", close != nil && close?.isHidden == false && close?.isEnabled == true && mini?.isEnabled == true && zoom?.isEnabled == true, "实际构造 NSWindow 检查按钮对象，没有模拟鼠标或显示窗口")
        try check("主窗口调度行为与浮窗分离", window.level == .normal && window.collectionBehavior.contains(.managed) && window.collectionBehavior.contains(.participatesInCycle) && !window.collectionBehavior.contains(.transient) && !window.collectionBehavior.contains(.fullScreenAuxiliary) && !window.isExcludedFromWindowsMenu && panel.collectionBehavior.contains(.transient) && panel.collectionBehavior.contains(.ignoresCycle) && panel.isExcludedFromWindowsMenu, "原生窗口属性核验，主窗参与调度；浮窗轻量，实际 Mission Control 未点击")
        let bundle = Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        try check("构建应用具有普通应用身份", StudioPresentation.activationPolicy == .regular && bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool == false && bundle?.bundleIdentifier == AppIdentity.bundleID && bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == AppIdentity.version && bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == AppIdentity.buildNumber, "核验编译包 Info.plist 与启动策略；未声称 Dock/Cmd-Tab 已实测")

        let delegate = StudioAppDelegate()
        let menu = delegate.makeMenu()
        let closeEntry = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "关闭工作台" }
        let quitEntry = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "退出镜生 H3" }
        try check("关闭与退出具有独立标准快捷键", closeEntry?.keyEquivalent == "w" && quitEntry?.keyEquivalent == "q" && closeEntry?.action != quitEntry?.action && closeEntry?.target === delegate && quitEntry?.target === delegate && app.windowsMenu?.title == "窗口" && app.servicesMenu?.title == "服务", "关闭 Cmd-W、退出 Cmd-Q，独立选择器与标准窗口/服务菜单")
        let dock = delegate.applicationDockMenu(app)
        try check("Dock 入口绑定打开主工作台", dock?.items.first?.title == "打开生成工作台" && dock?.items.first?.target === delegate && dock?.items.first?.action == #selector(StudioAppDelegate.showMain), "核验菜单目标；不调用前置窗口，不抢其他应用焦点")
        return (app, delegate, window, panel)
    }

    static func run(root: URL, executable: URL, includeNativeUI: Bool = true, check: (String, Bool, String) throws -> Void) async throws {
        let native = includeNativeUI ? try nativeChecks(executable: executable, check: check) : nil
        defer { native?.2.close(); native?.3.close() }

        let idle = try TaskStore(root: root.appendingPathComponent("idle"), executable: executable, monitoring: false)
        let blocked = ShotJob(shot: 97, segment: "quit-h3", title: "只等待 H3", prompt: "", requestedDuration: 2, engine: .h3, status: .blocked)
        idle.add(blocked)
        let idleFlow = StudioQuitFlow()
        try check("无自有运行任务退出不取消等待 H3", idleFlow.request(store: idle) == .terminateNow && idle.state.jobs.first?.status == .blocked && idle.launchCount == 0 && idle.state.queuePaused, "不会把等待模型任务当作正在下载的进程，也不访问下载任务")

        let running = try TaskStore(root: root.appendingPathComponent("running"), executable: executable, monitoring: false)
        native?.1.store = running
        let job = ShotJob.fixture(shot: 98, title: "退出语义 CPU 验证", delay: 0.08)
        let next = ShotJob.fixture(shot: 99, title: "退出后的队列保留")
        running.add(job); running.add(next); running.startQueue()
        try await StudioSelfTests.wait("退出验证进度") { running.activeJob?.progress != nil }
        let pid = running.activeJob?.workerPID
        if let (app, delegate, window, _) = native {
            window.performClose(nil)
            try check("关闭窗口不退出或停止当前生成", !delegate.applicationShouldTerminateAfterLastWindowClosed(app) && running.activeJob?.workerPID == pid && running.activeJob?.status == .running && !running.state.queuePaused && running.launchCount == 1, "仅关闭本测试隐藏窗口，自有 CPU 生成继续；未操作用户工作台")
        }
        let flow = StudioQuitFlow()
        let initial = flow.request(store: running)
        guard case .confirm(let prompt) = initial else { throw StudioError.invalid("运行退出缺少确认") }
        try check("退出前提示保留输出与独立下载", prompt.jobID == job.id && prompt.explanation.contains("候选文件与日志") && prompt.explanation.contains("退出不会停止它") && running.activeJob?.status == .running && !running.state.queuePaused, "请求退出不会先杀生成或暂停队列，等待明确选择")
        try check("重复退出不重复询问或取消", flow.request(store: running) == .alreadyPending && running.activeJob?.workerPID == pid && running.launchCount == 1, "多次请求只保留一个决定，运行进程不变")
        try check("选择继续生成保持队列原语义", flow.choose(exit: false, store: running) == .keepRunning && running.activeJob?.workerPID == pid && running.activeJob?.status == .running && !running.state.queuePaused, "拒绝退出不触发 shutdown、不改变队列暂停状态")
        let sentinel = Process(); sentinel.executableURL = URL(fileURLWithPath: "/bin/cat")
        sentinel.standardInput = Pipe(); sentinel.standardOutput = FileHandle.nullDevice; sentinel.standardError = FileHandle.nullDevice
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() } }
        _ = flow.request(store: running)
        let chosen = flow.choose(exit: true, store: running)
        try check("明确退出只取消自有当前任务", chosen == .waitForWorker && running.activeJob?.status == .cancelling && running.state.queuePaused && sentinel.isRunning && running.state.jobs[1].status == .queued, "独立测试 sentinel 仍在运行；后续未启动，等待任务不被删除")
        try await StudioSelfTests.wait("明确退出后的 worker 结束") { running.activeJob == nil }
        let attempt = running.state.jobs[0].attempts[0]
        try check("退出取消保留已写帧和错误日志", running.state.jobs[0].status == .cancelled && FileManager.default.fileExists(atPath: attempt.directory + "/frames/frame-0000.ppm") && FileManager.default.fileExists(atPath: attempt.directory + "/engine.log") && sentinel.isRunning && running.launchCount == 1, "真实自有 CPU worker 已停止，未杀外部模型或下载进程")

        let race = try TaskStore(root: root.appendingPathComponent("race"), executable: executable, monitoring: false)
        let first = ShotJob.fixture(shot: 100, title: "提示时的任务", delay: 0.008)
        let second = ShotJob.fixture(shot: 101, title: "确认前已切到另一任务", delay: 0.08)
        race.add(first); race.add(second); race.startQueue()
        let raceFlow = StudioQuitFlow(); _ = raceFlow.request(store: race)
        try await StudioSelfTests.wait("退出提示期间切换镜头") { race.activeJob?.id == second.id }
        let raceChoice = raceFlow.choose(exit: true, store: race)
        guard case .confirm(let changedPrompt) = raceChoice else { throw StudioError.invalid("退出确认误用了上一镜头授权") }
        try check("退出提示期间换任务需重新确认", changedPrompt.jobID == second.id && race.activeJob?.status == .running && !race.state.queuePaused && race.state.jobs[0].status == .completed, "新镜头没有被旧标题的确认取消")
        _ = raceFlow.choose(exit: false, store: race)
        race.pauseQueue()
        try await StudioSelfTests.wait("退出竞态测试自然完成") { race.activeJob == nil }
    }
}
