import AppKit

enum StudioPresentation {
    static let activationPolicy: NSApplication.ActivationPolicy = .regular

    @MainActor static func mainWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "镜生 H3 · 万神纪"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.isExcludedFromWindowsMenu = false
        window.minSize = NSSize(width: 1000, height: 730)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor static func orbWindow() -> OrbFloatingPanel {
        let panel = OrbFloatingPanel(contentRect: NSRect(origin: .zero, size: OrbGeometry.windowSize),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "镜生 H3 悬浮球"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

struct StudioQuitPrompt: Equatable {
    let jobID: UUID
    let title: String
    let alreadyCancelling: Bool
    var continueLabel: String { alreadyCancelling ? "留在应用" : "继续生成" }
    var explanation: String {
        "镜头“\(title)”仍在执行。退出会取消本应用当前任务并暂停后续队列，保留已写出的候选文件与日志。再次打开后需手动重试。\n\n独立的 H3 模型下载不由本应用管理，退出不会停止它。"
    }
}

/// Shared by the native quit dialog and headless tests; only an explicit choice stops a worker.
@MainActor final class StudioQuitFlow {
    enum Step: Equatable {
        case confirm(StudioQuitPrompt)
        case alreadyPending
        case keepRunning
        case terminateNow
        case waitForWorker
    }
    private enum Phase { case idle, awaiting(UUID), stopping }
    private var phase: Phase = .idle

    private func confirmation(_ job: ShotJob) -> Step {
        phase = .awaiting(job.id)
        return .confirm(StudioQuitPrompt(jobID: job.id, title: job.title, alreadyCancelling: job.status == .cancelling))
    }
    func request(store: TaskStore) -> Step {
        guard case .idle = phase else { return .alreadyPending }
        if let active = store.ownedActiveTask { return confirmation(active) }
        phase = .stopping; store.shutdown()
        return .terminateNow
    }
    func choose(exit: Bool, store: TaskStore) -> Step {
        guard case .awaiting(let promptedID) = phase else { return .alreadyPending }
        guard exit else { phase = .idle; return .keepRunning }
        // The shown shot can finish while the sheet is open. Never cancel a different shot
        // using consent that named the old one; show its new title and ask again.
        if let current = store.ownedActiveTask, current.id != promptedID { return confirmation(current) }
        phase = .stopping; store.shutdown()
        return store.ownedActiveTask == nil ? .terminateNow : .waitForWorker
    }
}
