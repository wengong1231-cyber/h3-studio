import SwiftUI
import AppKit
import AVKit

/// A preview never plays in the inspector. All playback belongs to the larger
/// window, which is independent of queue polling and inspector selection.
struct CandidateVideoPreview: View {
    let path: String
    let title: String
    @State private var failure: String?
    var body: some View {
        Button {
            do { try CandidatePlaybackController.shared.open(path:path,title:title) }
            catch { failure = error.localizedDescription }
        } label: {
            ZStack {
                Color.black
                CandidatePlayer(path:path).allowsHitTesting(false).accessibilityHidden(true)
                VStack(spacing:8) {
                    Image(systemName:"play.circle.fill").font(.system(size:36))
                    Text("点击放大播放").font(.system(size:12,weight:.medium))
                }.foregroundStyle(.white).padding(12)
                    .background(.black.opacity(0.55),in:RoundedRectangle(cornerRadius:12))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).clipShape(RoundedRectangle(cornerRadius:10))
            .help("在大窗口中播放候选视频")
            .accessibilityLabel(title + "，放大播放候选视频")
            .accessibilityIdentifier("candidate.open-playback")
            .alert("候选视频无法打开",isPresented:Binding(get:{ failure != nil },set:{ if !$0 { failure = nil } })) {
                Button("好") { failure = nil }
            } message: { Text(failure ?? "") }
    }
}

@MainActor final class CandidatePlaybackSession: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published private(set) var failure: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    private(set) var started = false
    private(set) var closed = false
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var seeking: UUID?

    init(path: String) throws {
        url = URL(fileURLWithPath:path).standardizedFileURL
        guard (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath:url.path) else {
            throw StudioError.invalid("候选视频已移动或暂不可读。请在任务中查看候选目录，恢复文件位置或系统访问权限后再打开。")
        }
        let item = AVPlayerItem(url:url)
        player = AVPlayer(playerItem:item)
        player.actionAtItemEnd = .pause
        statusObservation = item.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                guard let self,!self.closed else { return }
                if failed {
                    self.player.pause()
                    self.failure = "这个候选无法解码播放。请检查文件是否完整及视频格式；原候选和任务记录保留。"
                }
                self.refreshClock()
            }
        }
        rateObservation = player.observe(\.rate,options:[.initial,.new]) { [weak self] _,_ in
            Task { @MainActor [weak self] in
                guard let self,!self.closed else { return }
                self.playing = self.player.rate > 0
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.1,preferredTimescale:600),queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshClock() }
        }
    }
    func start() {
        guard !started,!closed else { return }
        started = true
        player.play()
    }
    private func refreshClock() {
        guard !closed else { return }
        let length = player.currentItem?.duration.seconds ?? 0
        if length.isFinite,length > 0,duration != length { duration = length }
        let current = player.currentTime().seconds
        if seeking == nil,current.isFinite { position = max(0,current) }
    }
    func togglePlayback() {
        guard !closed,failure == nil else { return }
        if player.rate > 0 { player.pause() }
        else {
            if duration > 0,position >= duration-0.05 { seek(to:0) }
            player.play()
        }
    }
    func seek(to seconds: Double) {
        guard !closed,seconds.isFinite,duration > 0 else { return }
        let token = UUID();seeking = token
        position = min(duration,max(0,seconds))
        player.currentItem?.cancelPendingSeeks()
        player.seek(to:CMTime(seconds:position,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,!self.closed,self.seeking == token else { return }
                self.seeking = nil;self.refreshClock()
            }
        }
    }
    func stop() {
        closed = true
        player.pause()
        playing = false
        seeking = nil
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver);self.timeObserver = nil }
    }
}

private struct ExpandedCandidatePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        // Keep the native view: the SwiftUI VideoPlayer overlay crashes on
        // this deployment runtime. Only the frame changes when resizing.
        let view = AVPlayerView()
        // A persistent SwiftUI control bar below the video remains usable even
        // when this macOS runtime fails to expose AVKit's hover controls.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.setAccessibilityLabel("放大候选视频播放器")
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView,context: Context) {
        if view.player !== player { view.player?.pause();view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView,coordinator: ()) {
        view.player?.pause()
        // Defer AVKit focus-chain teardown until SwiftUI finishes removal.
        DispatchQueue.main.async { view.player = nil }
    }
}

private struct CandidatePlaybackContent: View {
    @ObservedObject var session: CandidatePlaybackSession
    let close: () -> Void
    let fullScreen: () -> Void
    var body: some View {
        VStack(spacing:0) {
            ZStack {
                Color.black
                ExpandedCandidatePlayer(player:session.player)
                if let failure = session.failure {
                    Text(failure).foregroundStyle(.white).padding(24)
                        .background(.black.opacity(0.85),in:RoundedRectangle(cornerRadius:12))
                        .frame(maxWidth:520).accessibilityIdentifier("candidate.playback-error")
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack(spacing:12) {
                Button(action:session.togglePlayback) {
                    Label(session.playing ? "暂停" : "播放",systemImage:session.playing ? "pause.fill" : "play.fill")
                }.keyboardShortcut(.space,modifiers:[])
                    .disabled(session.failure != nil).accessibilityIdentifier("candidate.toggle-playback")
                Text(time(session.position)).font(.system(size:11,design:.monospaced)).monospacedDigit().frame(width:48)
                Slider(value:Binding(get:{ min(session.position,max(session.duration,0.001)) },set:{ session.seek(to:$0) }),in:0...max(session.duration,0.001))
                    .disabled(session.duration <= 0 || session.failure != nil)
                    .accessibilityLabel("播放进度（秒）").accessibilityIdentifier("candidate.playback-position")
                Text(time(session.duration)).font(.system(size:11,design:.monospaced)).monospacedDigit().frame(width:48)
                Button("全屏",action:fullScreen).help("进入或退出全屏")
                    .accessibilityIdentifier("candidate.toggle-fullscreen")
                Button("关闭播放窗",action:close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("candidate.close-playback")
            }.padding(.horizontal,16).padding(.vertical,10)
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = max(0,seconds.isFinite ? seconds : 0)
        return String(format:"%02d:%04.1f",Int(value)/60,value.truncatingRemainder(dividingBy:60))
    }
}

private final class CandidatePlaybackWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor final class CandidatePlaybackController: NSObject, NSWindowDelegate {
    static let shared = CandidatePlaybackController()
    private(set) var window: NSWindow?
    private(set) var session: CandidatePlaybackSession?

    static func contentSize(visibleFrame: NSRect) -> NSSize {
        NSSize(width:min(1100,max(320,visibleFrame.width-64)),
               height:min(720,max(240,visibleFrame.height-84)))
    }
    func open(path: String,title: String) throws {
        let url = URL(fileURLWithPath:path).standardizedFileURL
        if let window,session?.url == url {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps:true)
            return // A repeated click raises the same player, without seeking.
        }
        let next = try CandidatePlaybackSession(path:path)
        window?.close()
        session = next
        let screen = NSApplication.shared.keyWindow?.screen ?? NSScreen.main
        let size = Self.contentSize(visibleFrame:screen?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800))
        let panel = CandidatePlaybackWindow(contentRect:NSRect(origin:.zero,size:size),
            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        panel.title = title + " · 候选视频"
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width:min(640,size.width),height:min(420,size.height))
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView:CandidatePlaybackContent(session:next,
            close:{ [weak panel] in panel?.performClose(nil) },fullScreen:{ [weak panel] in panel?.toggleFullScreen(nil) }))
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps:true)
        next.start()
    }
    func closeIfKey() -> Bool {
        guard let window,window.isKeyWindow else { return false }
        window.performClose(nil)
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,closing === window else { return }
        session?.stop()
        session = nil
        window = nil
    }
}
