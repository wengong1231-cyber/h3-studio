import AppKit
import SwiftUI
import Darwin

final class OrbFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    var store: TaskStore!
    private var mainWindow: NSWindow?
    private var orbWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private var workspaceContext: ResolvedWorkspace?
    private let quitFlow = StudioQuitFlow()
    private var subscriptions: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = CommandLine.arguments
            let root: URL
            let locations: ExternalLocations
            if let index = arguments.firstIndex(of: "--workspace"), index + 1 < arguments.count {
                root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                locations = .defaults
            } else {
                let context = try WorkspaceMigrator(supportRoot: WorkspaceMigrator.defaultSupportRoot).resolve(legacyHint: WorkspaceMigrator.legacyHint())
                workspaceContext = context
                root = context.root; locations = context.settings.externalLocations
            }
            store = try TaskStore(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, locations: locations)
            store.startupLog.record(.workspaceResolved)
            store.startupLog.record(.stateLoaded)
            PreviewImageService.shared.configureDiagnostics(root:root)
            if arguments.contains("--demo") { store.seedFixtures() }
            if arguments.contains("--dark") { store.setTheme("dark") }
            if arguments.contains("--light") { store.setTheme("light") }
            makeMenu()
            store.startupLog.record(.menuCreated)
            makeMainWindow()
            store.startupLog.record(.mainWindowCreated)
            makeOrb()
            store.startupLog.record(.orbCreated)
            makeStatusItem()
            showMain()
            showOrb()
            store.startupLog.record(.uiPresented)
            DispatchQueue.main.async { [weak self] in
                self?.store?.startBackgroundStatus()
                self?.store?.startBackgroundHistory()
                self?.store?.startBackgroundFirstProposals()
                if let self,!arguments.contains("--skip-planned-queue") {
                    let url: URL
                    if let index = arguments.firstIndex(of:"--import-planned-queue"),index+1 < arguments.count {
                        url = URL(fileURLWithPath:arguments[index+1]).standardizedFileURL
                    } else { url = H3QueuePlan.knownPath }
                    Task { @MainActor in
                        let exists = await Task.detached(priority:.utility) { FileManager.default.fileExists(atPath:url.path) }.value
                        if exists {
                            do { _ = try await self.store.importPlannedQueue(url) }
                            catch { self.store.notice = error.localizedDescription }
                        }
                    }
                }
                if let self,let index = arguments.firstIndex(of:"--import-first-proposal"),index+1 < arguments.count {
                    Task { @MainActor in
                        do {
                            let id = try await self.store.importFirstProposal(URL(fileURLWithPath:arguments[index+1]).standardizedFileURL)
                            if arguments.contains("--start-imported") { await self.store.startAuthorizedFirst(id) }
                        } catch { self.store.notice = error.localizedDescription }
                    }
                }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "镜生 H3 无法启动"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "关闭"); alert.runModal(); NSApplication.shared.terminate(nil)
        }
    }
    private func makeMainWindow() {
        let window = StudioPresentation.mainWindow()
        window.setFrameAutosaveName("WanshenjiH3Studio.MainWindow")
        window.contentView = NSHostingView(rootView: StudioView(store: store, telemetry: store.telemetry, readiness: store.readiness,
            showOrb: { [weak self] in self?.showOrb() }, closeWorkbench: { [weak self] in self?.closeWorkbench() }, requestQuit: { [weak self] in self?.requestQuit() }))
        window.center()
        mainWindow = window
    }
    private func makeOrb() {
        let panel = StudioPresentation.orbWindow()
        let hover = OrbHoverState()
        let host = OrbHostingView(rootView: OrbView(store: store, telemetry: store.telemetry, readiness: store.readiness, hover: hover, activate: {}))
        host.hoverState = hover
        host.onActivate = { [weak self] in self?.showMain() }
        host.onCommit = { [weak self] point in self?.store.setOrbOrigin(x: point.x, y: point.y) }
        host.rootView = OrbView(store: store, telemetry: store.telemetry, readiness: store.readiness, hover: hover, activate: { [weak host] in host?.activateFromAccessibility() })
        panel.contentView = host
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let desired = NSPoint(x: store.state.orbX ?? visible.maxX - 286, y: store.state.orbY ?? visible.minY + 90)
        panel.setFrameOrigin(OrbGeometry.constrained(desired, visibleFrames: NSScreen.screens.map(\.visibleFrame)))
        orbWindow = panel
    }
    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "镜生 H3")
        item.button?.toolTip = "镜生 H3 · 本地生成工作台"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开生成工作台", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "显示悬浮球", action: #selector(showOrb), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏悬浮球", action: #selector(hideOrb), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出镜生 H3", action: #selector(requestQuit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu; statusItem = item
    }
    @discardableResult func makeMenu() -> NSMenu {
        let root = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(title: "镜生 H3")
        appMenu.addItem(withTitle: "关于镜生 H3", action: #selector(showAbout), keyEquivalent: "").target = self
        let services = NSMenu(title: "服务")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: ""); servicesItem.submenu = services
        appMenu.addItem(servicesItem); NSApplication.shared.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏镜生 H3", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApplication.shared
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.target = NSApplication.shared; hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApplication.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出镜生 H3", action: #selector(requestQuit), keyEquivalent: "q").target = self
        app.submenu = appMenu; root.addItem(app)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开生成工作台", action: #selector(showMain), keyEquivalent: "1").target = self
        fileMenu.addItem(withTitle: "关闭当前窗口", action: #selector(closeCurrentWindow), keyEquivalent: "w").target = self
        file.submenu = fileMenu; root.addItem(file)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; root.addItem(edit)
        let windows = NSMenuItem(); let windowsMenu = NSMenu(title: "窗口")
        windowsMenu.addItem(withTitle: "最小化", action: #selector(minimizeWorkbench), keyEquivalent: "m").target = self
        windowsMenu.addItem(withTitle: "打开生成工作台", action: #selector(showMain), keyEquivalent: "").target = self
        windowsMenu.addItem(.separator())
        windowsMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "").target = NSApplication.shared
        windows.submenu = windowsMenu; root.addItem(windows); NSApplication.shared.windowsMenu = windowsMenu
        NSApplication.shared.mainMenu = root
        return root
    }
    @objc func showMain() {
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func closeWorkbench() { mainWindow?.performClose(nil) }
    @objc private func closeCurrentWindow() {
        if !CandidatePlaybackController.shared.closeIfKey() { closeWorkbench() }
    }
    @objc private func minimizeWorkbench() { mainWindow?.performMiniaturize(nil) }
    @objc func showOrb() { orbWindow?.orderFrontRegardless() }
    @objc private func hideOrb() { orbWindow?.orderOut(nil) }
    @objc private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: AppIdentity.name, .applicationVersion: AppIdentity.version, .credits: NSAttributedString(string: "万神纪 · 本地 H3 单镜工作台\n已授权任务自动生成并检查输出；实际进度和候选保存在本机。")])
    }
    @objc private func requestQuit() { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        let step = quitFlow.request(store: store)
        if step == .terminateNow { return .terminateNow }
        handleQuitStep(step, sender: sender)
        return .terminateLater
    }
    private func handleQuitStep(_ step: StudioQuitFlow.Step, sender: NSApplication) {
        switch step {
        case .confirm(let prompt):
            showMain()
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "退出前处理正在执行的任务"
            alert.informativeText = prompt.explanation
            alert.addButton(withTitle: prompt.continueLabel)
            alert.addButton(withTitle: "取消当前任务并退出")
            let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, let store = self.store else { sender.reply(toApplicationShouldTerminate: false); return }
                self.handleQuitStep(self.quitFlow.choose(exit: response == .alertSecondButtonReturn, store: store), sender: sender)
            }
            if let window = mainWindow { alert.beginSheetModal(for: window, completionHandler: respond) }
            else { respond(alert.runModal()) }
        case .keepRunning: sender.reply(toApplicationShouldTerminate: false)
        case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
        case .waitForWorker: waitForOwnedWorker(sender: sender)
        case .alreadyPending: break
        }
    }
    private func waitForOwnedWorker(sender: NSApplication) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(4)
            while store.ownedActiveTask != nil && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            // If a child fails to exit, closing the owner makes the fixture watchdog stop it.
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return false }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "镜生 H3")
        menu.addItem(withTitle: "打开生成工作台", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出镜生 H3", action: #selector(requestQuit), keyEquivalent: "").target = self
        return menu
    }
}

@main struct StudioEntry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of:"--h3-fidelity-worker"),index+1 < arguments.count {
            exit(H3FidelityWorker.run(URL(fileURLWithPath:arguments[index+1]).standardizedFileURL))
        }
        if let index = arguments.firstIndex(of:"--fidelity-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3FidelitySelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--receipt-rebind-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3ReceiptRebindSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--receipt-rebind-case-check"),index+2 < arguments.count {
            exit(H3ReceiptRebindSelfTests.caseCheck(handoff:URL(fileURLWithPath:arguments[index+1]),output:URL(fileURLWithPath:arguments[index+2])))
        }
        if let index = arguments.firstIndex(of:"--ready-frontier-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await ReadyFrontierSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--execution-focus-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await ExecutionFocusSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--execution-focus-layout-preview"),index+1 < arguments.count {
            exit(ExecutionFocusSelfTests.renderPreviews(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL))
        }
        if let index = arguments.firstIndex(of:"--static-input-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3StaticInputSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--video-review-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3VideoReviewSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--execution-activity-self-test"),index+1 < arguments.count {
            exit(ExecutionActivitySelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL))
        }
        if let index = arguments.firstIndex(of:"--action-revision-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3ActionRevisionSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--queue-execution-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3QueueExecutionSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL,executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--first-source-validation"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3FirstSelfTests.validateRealSource(root:URL(fileURLWithPath:arguments[index+1]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--queue-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3QueueSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--first-shot-self-test"),index+1 < arguments.count {
            Task { @MainActor in exit(await H3FirstSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) }
            RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--preview-self-test"),index + 1 < arguments.count {
            Task { @MainActor in exit(await PreviewSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) };RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of: "--ui-gpu-self-test"), index + 1 < arguments.count {
            exit(TelemetrySelfTests.run(root: URL(fileURLWithPath: arguments[index + 1])))
        }
        if let index = arguments.firstIndex(of: "--automation-self-test"), index + 1 < arguments.count {
            Task { @MainActor in exit(await H3AutomationSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) };RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of: "--ui-gpu-layout-preview"), index + 1 < arguments.count {
            exit(TelemetrySelfTests.renderPreviews(root: URL(fileURLWithPath: arguments[index + 1])))
        }
        if let index = arguments.firstIndex(of:"--h3-ab-proposal-profile"),index+1<arguments.count {
            Task { @MainActor in exit(await H3ABSelfTests.proposalProfile(report:URL(fileURLWithPath:arguments[index+1]))) };RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--h3-ab-self-test"),index+1<arguments.count {
            Task { @MainActor in exit(await H3ABSelfTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) };RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of:"--h3-ab-mock-worker"),index+1<arguments.count { exit(H3ABMock.worker(URL(fileURLWithPath:arguments[index+1]))) }
        if let index=arguments.firstIndex(of:"--history-self-test"),index+1<arguments.count {
            Task { @MainActor in exit(await H3HistoryTests.run(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) };RunLoop.main.run();return
        }
        if let index=arguments.firstIndex(of:"--history-status-profile"),index+1<arguments.count {
            Task { @MainActor in exit(await H3HistoryTests.statusProfile(root:URL(fileURLWithPath:arguments[index+1]),executable:URL(fileURLWithPath:arguments[0]).standardizedFileURL)) };RunLoop.main.run();return
        }
        if let index = arguments.firstIndex(of: "--readiness-self-test"), index + 1 < arguments.count {
            Task { @MainActor in exit(await ReadinessSelfTests.run(root: URL(fileURLWithPath: arguments[index + 1]))) }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--readiness-status-profile"), index + 1 < arguments.count {
            Task { @MainActor in exit(await ReadinessSelfTests.statusProfile(report: URL(fileURLWithPath: arguments[index + 1]))) }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--startup-self-test"), index + 1 < arguments.count {
            Task { @MainActor in exit(await StartupSelfTests.run(root: URL(fileURLWithPath: arguments[index + 1]), executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL)) }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--startup-hung-exit-profile"), index + 1 < arguments.count {
            Task { @MainActor in exit(await StartupSelfTests.hungExitProfile(root: URL(fileURLWithPath: arguments[index + 1]), executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL)) }
            RunLoop.main.run(); return
        }
        for (flag, run) in [("--h3-worker", H3Supervisor.run), ("--h3-mock-wrapper", H3Mock.wrapper), ("--h3-mock-validator", H3Mock.validator)] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count { exit(run(URL(fileURLWithPath: arguments[index + 1]))) }
        }
        if let index = arguments.firstIndex(of: "--h3-self-test"), index + 1 < arguments.count {
            Task { @MainActor in
                exit(await H3SelfTests.run(root: URL(fileURLWithPath: arguments[index + 1]), executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL))
            }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--h3-crash-harness"), index + 1 < arguments.count {
            Task { @MainActor in await H3SelfTests.crashHarness(root: URL(fileURLWithPath: arguments[index + 1]), executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL) }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--fixture-worker"), index + 1 < arguments.count {
            exit(FixtureWorker.run(requestURL: URL(fileURLWithPath: arguments[index + 1])))
        }
        if let code = WorkspaceCommand.run(arguments: arguments) { exit(code) }
        if let flag = ["--self-test", "--self-test-core"].first(where: { arguments.contains($0) }), let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
            Task { @MainActor in
                let code = await StudioSelfTests.run(root: URL(fileURLWithPath: arguments[index + 1]), executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL, includeNativeUI: flag == "--self-test")
                exit(code)
            }
            RunLoop.main.run(); return
        }
        if let index = arguments.firstIndex(of: "--crash-harness"), index + 1 < arguments.count {
            var heldStore: TaskStore?
            do {
                let root = URL(fileURLWithPath: arguments[index + 1])
                let store = try TaskStore(root: root, executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL, monitoring: false)
                store.add(.fixture(shot: 77, title: "崩溃恢复验证", delay: 0.1)); store.startQueue(); heldStore = store
                try Data("ready".utf8).write(to: root.appendingPathComponent("harness-ready"))
                withExtendedLifetime(heldStore) { RunLoop.main.run() }
            } catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(StudioPresentation.activationPolicy)
        let delegate = StudioAppDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
