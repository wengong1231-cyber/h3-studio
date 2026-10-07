import SwiftUI
import AppKit

struct FocusVisibilityTimelineSchedule: TimelineSchedule {
    var isVisible: Bool
    func entries(from startDate: Date,mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence {
            var date = startDate,first = true
            return AnyIterator<Date> {
                guard isVisible || first else { return nil }
                defer { first = false;date = date.addingTimeInterval(1) }
                return date
            }
        }
    }
}

struct ExecutionFocusStrip: View {
    @ObservedObject var store: TaskStore
    var select: (UUID) -> Void
    @State private var windowVisible = false
    var body: some View {
        TimelineView(FocusVisibilityTimelineSchedule(isVisible:windowVisible)) { context in
            ExecutionFocusCards(projection:store.executionFocus(at:context.date),windowVisible:windowVisible,select:select)
        }
        .background(WindowVisibilityProbe { windowVisible = $0 }.frame(width:0,height:0))
    }
}

/// Only notification observation; no sampling timer, permissions or processes.
struct WindowVisibilityProbe: NSViewRepresentable {
    var changed: (Bool) -> Void
    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();detach()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in self?.sample() })
                }
                observers.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in self?.changed?(false) })
            }
            sample()
        }
        func sample() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor } ?? false
            DispatchQueue.main.async { [weak self] in self?.changed?(visible) }
        }
        func detach() { observers.forEach { NotificationCenter.default.removeObserver($0) };observers.removeAll() }
        deinit { detach() }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe();view.changed = changed;return view }
    func updateNSView(_ view: Probe,context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Probe,coordinator: ()) { view.detach();view.changed = nil }
}

struct ExecutionFocusCards: View {
    var projection: ExecutionFocusProjection
    var windowVisible: Bool
    var select: (UUID) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: Palette { Palette(scheme:scheme) }
    private var nextTextColor: Color { scheme == .dark ? .studioTeal : Color(red:0.16,green:0.43,blue:0.40) }
    private var animate: Bool { FocusMotionPolicy.shouldAnimate(mode:projection.current?.mode ?? .idle,reduceMotion:reduceMotion,windowVisible:windowVisible) }
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            currentCard.frame(maxWidth:.infinity,alignment:.leading)
            nextCard.frame(maxWidth:.infinity,alignment:.leading)
        }
        .accessibilityIdentifier("execution-focus-strip")
    }
    private var currentCard: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                Circle().fill(projection.current == nil ? Color.secondary.opacity(0.4) : Color.studioGold).frame(width:6,height:6)
                Text(projection.current?.mode == .preparation ? "当前正在准备 · CPU" : projection.current?.mode == .observed ? "当前观察外部任务" : "当前执行")
                    .font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                Spacer(minLength:4)
                if let current = projection.current { focusButton(current.job.id) }
            }
            if let current = projection.current {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(current.job.focusTaskLabel).font(.system(size:16,weight:.semibold)).lineLimit(1)
                    Spacer(minLength:2)
                    Text(current.activity.elapsed).font(.system(size:12,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
                }
                Text(current.activity.stage).font(.system(size:11,weight:.medium)).lineLimit(1).help(current.activity.stage)
                HStack(spacing:6) {
                    if let progress = current.activity.progress {
                        MeasuredStageProgressBar(progress:progress).frame(width:94,height:5)
                        Text(progress.label).font(.system(size:10,design:.monospaced)).lineLimit(1)
                    } else {
                        Text(current.mode == .preparation ? "正在准备实际输入" : current.mode == .cancelling ? "等待自有进程退出" : "当前阶段未提供可计算进度")
                            .font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(height:14)
                Text(current.activity.lastProgress).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1).help(current.activity.lastProgress)
                if projection.conflictingActiveRecords > 1 {
                    Text("记录中有多个活动任务，请检查日志").font(.system(size:9)).foregroundStyle(.red)
                }
            } else {
                Text("当前没有执行任务").font(.system(size:16,weight:.semibold))
                Text(projection.globalWait ?? "生成资源空闲").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                Text("选择任务查看输入、候选与记录").font(.system(size:10)).foregroundStyle(.secondary)
                Text("没有新的生成进展").font(.system(size:9)).foregroundStyle(.secondary)
            }
        }.frame(minHeight:117,alignment:.topLeading).padding(14)
            .background(palette.surface.overlay(Color.studioGold.opacity(projection.current == nil ? 0.015 : 0.05)))
            .clipShape(RoundedRectangle(cornerRadius:13))
            .overlay {
                TimelineView(.animation(minimumInterval:1.0/30.0,paused:!animate)) { context in
                    let seconds = animate ? context.date.timeIntervalSinceReferenceDate : 0
                    let phase = seconds.truncatingRemainder(dividingBy:10)/10
                    let opacity = animate ? 0.62 + 0.1*sin(seconds * .pi/2) : projection.current == nil ? 0.25 : 0.55
                    RoundedRectangle(cornerRadius:13).strokeBorder(
                        AngularGradient(colors:[.studioGold.opacity(0.35),.studioGold,.studioTeal.opacity(0.8),.studioGold.opacity(0.35)],center:.center,angle:.degrees(phase*360)),lineWidth:1.5)
                        .opacity(opacity)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .accessibilityElement(children:.contain).accessibilityIdentifier("current-execution-card")
    }
    private var nextCard: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                Image(systemName:"arrow.turn.down.right").font(.system(size:10)).foregroundStyle(Color.studioTeal)
                Text("下一项").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                Spacer(minLength:4)
                if let job = projection.next?.job ?? projection.waitingJob { focusButton(job.id) }
            }
            if let next = projection.next {
                Text(next.job.focusTaskLabel).font(.system(size:16,weight:.semibold)).lineLimit(1)
                Text(next.stateLabel).font(.system(size:11,weight:.medium)).foregroundStyle(nextTextColor).lineLimit(1)
                Text(next.detail).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).help(next.detail)
                Text(next.orderLabel).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(projection.waitingJob == nil ? "暂无待执行任务" : "暂无就绪任务").font(.system(size:16,weight:.semibold))
                Text(projection.waitingJob.map { $0.focusTaskLabel + " · 条件未齐" } ?? "已登记任务均已结束")
                    .font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                Text(projection.waitingReason ?? "完成的候选与输出持续保留").font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).help(projection.waitingReason ?? "")
                Text("等待条件就绪时不会显示为正在执行").font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(minHeight:117,alignment:.topLeading).padding(14)
            .background(palette.surface.overlay(Color.studioTeal.opacity(0.025))).clipShape(RoundedRectangle(cornerRadius:13))
            .overlay(RoundedRectangle(cornerRadius:13).strokeBorder(LinearGradient(colors:[.studioTeal.opacity(0.4),.studioGold.opacity(0.18)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1))
            .accessibilityElement(children:.contain).accessibilityIdentifier("next-execution-card")
    }
    private func focusButton(_ id: UUID) -> some View {
        Button { select(id) } label: { Label("定位",systemImage:"arrow.up.right").font(.system(size:9,weight:.medium)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("选择并定位此任务的详情")
    }
}

struct MeasuredStageProgressBar: View {
    var progress: StageProgress
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.studioGold.opacity(0.16))
                if progress.total > 0 && (0...progress.total).contains(progress.completed) {
                    Capsule().fill(Color.studioGold).frame(width:geometry.size.width * progress.fraction)
                }
            }
        }.accessibilityLabel("当前阶段进度").accessibilityValue(progress.label)
    }
}

struct RedoTaskRouteCard: View {
    var route: RedoRouteResolution
    var open: (UUID?) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Button { open(nil) } label: {
                HStack(spacing:7) { Image(systemName:"arrow.turn.up.right");Text("查看重做任务").fontWeight(.medium);Spacer(minLength:0);Image(systemName:"chevron.right").font(.system(size:9)) }
                    .font(.system(size:11)).padding(.vertical,5)
            }.buttonStyle(.plain).disabled(route.target == nil).accessibilityIdentifier("view-redo-task")
            Text(route.target?.label ?? route.unavailableReason ?? "没有关联的重做任务")
                .font(.system(size:9)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            if route.history.count > 1 {
                Menu("查看重做历史（\(route.history.count)）") {
                    ForEach(route.history) { target in Button(target.label) { open(target.jobID) } }
                }.font(.system(size:9)).menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(12).background(Palette(scheme:scheme).raised.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius:9))
    }
}
