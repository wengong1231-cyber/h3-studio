import SwiftUI
import AppKit
import AVKit
import Charts
import UniformTypeIdentifiers

extension Color {
    static let studioGold = Color(red: 0.79, green: 0.64, blue: 0.38)
    static let studioTeal = Color(red: 0.29, green: 0.67, blue: 0.64)
}

@MainActor private func cancelQueueTaskFromUI(_ id: UUID, store: TaskStore) {
    // A filtered list may collapse after the first click. A double click must not
    // cancel the next row that happens to move underneath the same pointer.
    if let event = NSApp?.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1 { return }
    let event = NSApp?.currentEvent
    store.cancel(id,source:"App UI action; event=" + (event.map { String($0.type.rawValue) } ?? "unavailable") + "; clicks=" + (event.map { String($0.clickCount) } ?? "unavailable"))
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(Color.black.opacity(enabled ? 0.9 : 0.45))
            .background(Color.studioGold.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct Palette {
    var scheme: ColorScheme
    var background: Color { scheme == .dark ? Color(red: 0.067, green: 0.083, blue: 0.108) : Color(red: 0.96, green: 0.96, blue: 0.95) }
    var surface: Color { scheme == .dark ? Color(red: 0.099, green: 0.12, blue: 0.15) : .white }
    var raised: Color { scheme == .dark ? Color(red: 0.14, green: 0.16, blue: 0.19) : Color(red: 0.94, green: 0.94, blue: 0.93) }
    var border: Color { Color.primary.opacity(scheme == .dark ? 0.08 : 0.07) }
}

extension JobStatus {
    var color: Color {
        switch self {
        case .running, .cancelling: return .studioGold
        case .completed: return .studioTeal
        case .failed, .interrupted: return .red.opacity(0.85)
        default: return .secondary
        }
    }
    var icon: String {
        switch self {
        case .queued: return "clock"
        case .running: return "waveform.path"
        case .cancelling: return "stop.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .interrupted: return "arrow.counterclockwise.circle"
        case .blocked: return "link"
        }
    }
}

struct StudioView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var telemetry: TelemetryMonitor
    @ObservedObject var readiness: ModelReadinessMonitor
    var showOrb: () -> Void
    var closeWorkbench: () -> Void
    var requestQuit: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var filter = "all"
    @State private var adding = false
    @State private var staticInputs = false
    @State private var rejectingCandidate: ShotJob?
    @State private var fidelityCandidate: ShotJob?
    @State private var metrics = false
    @State private var models = false
    @State private var inspectorTab = 0
    private var palette: Palette { Palette(scheme: scheme) }
    private var taskGroups: [TaskVersionGroup] { TaskVersionGrouping.project(store.state.jobs) }
    private var jobs: [TaskVersionGroup] { taskGroups.filter { $0.matches(filter) } }
    private var selectedGroup: TaskVersionGroup? { taskGroups.first { $0.contains(store.selectedID) } }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 164)
            Rectangle().fill(palette.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(palette.border).frame(height: 1)
                ExecutionFocusStrip(store:store) { id in _ = store.navigateToTask(id,from:navigationLocation) }
                    .padding(.horizontal,20).padding(.vertical,14)
                if !models { ModelDownloadBar(monitor: readiness) { metrics = false; models = true } }
                if let fault = store.storageFault { banner(fault, icon: "externaldrive.badge.exclamationmark", color: .red) }
                else if let notice = store.notice {
                    HStack {
                        banner(notice, icon: "info.circle", color: .studioGold)
                        Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain).padding(.trailing, 20).help("关闭提示")
                    }.background(Color.studioGold.opacity(0.05))
                }
                if models { ModelPreparationView(monitor: readiness, store: store).padding(22) }
                else if metrics { PerformanceView(monitor: telemetry, store: store).padding(20).transition(.opacity) }
                else {
                    HStack(spacing: 0) {
                        queue
                        Rectangle().fill(palette.border).frame(width: 1)
                        inspector.frame(width: 302)
                    }
                }
                footer
            }
        }
        .background(palette.background)
        .foregroundStyle(Color.primary)
        .font(.system(size: 12))
        .frame(minWidth: 1000, minHeight: 680)
        .preferredColorScheme(store.state.theme == "dark" ? .dark : store.state.theme == "light" ? .light : nil)
        .sheet(isPresented: $adding) { AddJobView(store: store) }
        .sheet(isPresented: $staticInputs) { H3StaticInputLibrarySheet(store:store) }
        .sheet(item:$rejectingCandidate) { H3VideoRejectionSheet(store:store,job:$0) }
        .sheet(item:$fidelityCandidate) { H3FidelitySheet(store:store,jobID:$0.id) }
        .onChange(of:store.navigationIntent?.id) { _,_ in
            guard let location = store.navigationIntent?.destination else { return }
            filter = location.filter;inspectorTab = location.inspectorTab;metrics = location.metrics;models = location.models
        }
    }

    private var navigationLocation: TaskNavigationLocation {
        .init(selectedID:store.selectedID,filter:filter,inspectorTab:inspectorTab,metrics:metrics,models:models)
    }
    private func openRedo(_ origin: ResultRouteOrigin,target: UUID? = nil) {
        _ = store.navigateToRedo(origin,from:navigationLocation,historyTarget:target)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.studioGold.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 19)).foregroundStyle(Color.studioGold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("镜生 H3").font(.system(size: 16, weight: .semibold))
                    Text("LOCAL STUDIO").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.7).foregroundStyle(.secondary)
                }
            }.padding(.top, 25).padding(.bottom, 33)
            Text("工作区").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 11).padding(.leading, 12)
            navigation("镜头队列", icon: "square.stack.3d.up", value: "all", count: taskGroups.count)
            navigation("等待与生成", icon: "waveform.path", value: "active", count: taskGroups.filter { $0.matches("active") }.count)
            navigation("候选输出", icon: "play.rectangle", value: "completed", count: taskGroups.filter { $0.matches("completed") }.count)
            navigation("需要处理", icon: "exclamationmark.circle", value: "errors", count: taskGroups.filter { $0.matches("errors") }.count)
            Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, 21).padding(.horizontal, 12)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { metrics.toggle(); models = false }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chart.xyaxis.line").frame(width: 16)
                    Text("设备性能")
                    Spacer()
                    Circle().fill(telemetry.enabled ? Color.studioTeal : .secondary).frame(width: 5, height: 5)
                }.padding(11).background(metrics && !models ? palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            Button { models = true; metrics = false } label: {
                HStack(spacing: 9) { Image(systemName: "square.and.arrow.down").frame(width: 16); Text("模型准备"); Spacer() }
                    .padding(11).background(models ? palette.raised : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            Button(action: showOrb) {
                Label("桌面悬浮球", systemImage: "circle.circle").padding(11)
            }.buttonStyle(.plain).help("显示可拖动的悬浮球")
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(Color.studioGold).frame(width: 5, height: 5)
                    Text("原生单镜 / CPU 验证").font(.system(size: 11, weight: .medium))
                }
                Text("H3 串行自动生成\n候选输出独立保存")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
                HStack {
                    Text("外观").foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("跟随系统") { store.setTheme("system") }
                        Button("浅色") { store.setTheme("light") }
                        Button("深色") { store.setTheme("dark") }
                    } label: { Image(systemName: store.state.theme == "dark" ? "moon" : "circle.lefthalf.filled") }
                    .menuStyle(.borderlessButton).frame(width: 28).help("切换浅色、深色或跟随系统")
                }.padding(.top, 5)
            }.padding(12).background(palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                Button(action: closeWorkbench) { Label("关闭工作台", systemImage: "xmark.rectangle") }
                    .help("关闭此窗口，悬浮球与当前任务继续；可从 Dock 重新打开")
                Spacer(minLength: 0)
                Button("退出应用", action: requestQuit)
                    .accessibilityLabel("退出镜生 H3")
                    .help("退出镜生 H3；有正在生成的任务时会先询问")
            }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(0.8)).padding(.horizontal, 4).padding(.top, 14)
        }.padding(.horizontal, 13).padding(.bottom, 18).background(palette.surface.opacity(0.6))
    }
    private func navigation(_ label: String, icon: String, value: String, count: Int) -> some View {
        Button {
            filter = value; metrics = false; models = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(label)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(11)
                .background(filter == value && !metrics && !models ? Color.studioGold.opacity(0.12) : .clear)
                .foregroundStyle(filter == value && !metrics && !models ? Color.studioGold : Color.primary.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.bottom, 3)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("万神纪 / 本地工作区").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(models ? "模型准备" : metrics ? "设备性能" : "镜头生成").font(.system(size: 23, weight: .semibold))
            }
            Spacer()
            Menu {
                Button("完整图库与静态首图…") { staticInputs = true }
                Divider()
                Button("导入后续17镜计划") {
                    Task { do { _ = try await store.importPlannedQueue(H3QueuePlan.knownPath) } catch { store.notice = error.localizedDescription } }
                }
                Button("准备下一可执行段") { Task { await store.prepareNextPlannedJob() } }
                Divider()
                Button("创建 S41 A/B 重做任务") { createS41Known() }
                Button("从文件创建 A/B 任务",action:importS41Configuration)
                Divider()
                Button("绑定已核 S15 单镜",action:importH3Job)
            } label: { Label("新建 H3",systemImage:"sparkles") }
                .menuStyle(.borderlessButton).fixedSize().disabled(store.abConfigurationBusy)
            Menu {
                Button("同步三条真实 H3 记录") { store.importKnownHistoryInBackground() }
                Button("只读导入外部 H3 记录",action:importH3History)
                Button("导入镜头清单",action:importManifest)
            } label: { Label("导入记录",systemImage:"square.and.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize().disabled(store.historyImportInFlight)
            Button { adding = true } label: { Label("添加任务", systemImage: "plus").padding(.horizontal, 5) }
                .buttonStyle(StudioPrimaryButtonStyle())
                .controlSize(.regular).keyboardShortcut("n", modifiers: .command)
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                stat("替换镜头", value: "\(store.replacementShotCount)/18", caption: "按镜号去重")
                stat("图片", value: "\(store.staticImageCount)", caption: "完整图库", color: .studioTeal)
                stat("视频分段", value: "\(store.currentVideoSegmentCount)", caption: "当前版本 · 并发 1")
            }.padding(.horizontal, 20).padding(.vertical, 20)
            HStack {
                Text("镜头队列").font(.system(size: 13, weight: .semibold))
                Text("\(jobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if store.queueDispatchEnabled {
                    Button { store.pauseQueue() } label: { Label("暂停队列", systemImage: "pause.fill") }.buttonStyle(.bordered)
                        .help("暂停所有后续启动；当前镜头继续生成，输入核对和已完成输出保留")
                } else {
                    if store.hasAuthorizedFirstContinuations {
                        Button { Task { await store.resumeAuthorizedFirstQueue() } } label: { Label("继续已授权流程",systemImage:"play.fill") }
                            .buttonStyle(.bordered).disabled(!store.singleGeneratorIdle)
                            .help("恢复已开始任务的图审核对与接续；等待验收的依赖段继续等待，独立就绪任务可运行")
                    }
                    Button { store.startQueue() } label: { Label("开始队列", systemImage: "play.fill") }
                        .buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.canStart)
                        .help("串行启动 CPU 合成验证。H3 镜头使用各自的开始按钮，自动完成后续流程。")
                }
            }.padding(.horizontal, 20).padding(.bottom, 14)
            Text("重做收在同一任务的版本历史中；每行显示当前版本。待执行项可上移、下移或拖动排序。")
                .font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10)
            HStack {
                Text("参考 / 镜头"); Spacer(); Text("阶段与状态"); Text("耗时").frame(width: 42, alignment: .trailing)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, 20)
            if jobs.isEmpty { emptyQueue }
            else {
                ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(jobs) { group in
                            let job = group.current
                            ShotRow(job: job, title: group.title, versionCount: group.versions.count,
                                    relationshipIssue: group.relationshipIssue, selected: group.contains(store.selectedID),
                                    canMoveUp: store.canMovePending(job.id, offset: -1), canMoveDown: store.canMovePending(job.id, offset: 1),
                                    select: { store.selectedID = job.id; inspectorTab = 0 },
                                    moveUp: { store.movePending(job.id, offset: -1) }, moveDown: { store.movePending(job.id, offset: 1) },
                                    cancel: { cancelQueueTaskFromUI(job.id, store: store) }, retry: { store.retry(job.id) },
                                    drop: { sourceID in store.movePending(sourceID, before: job.id) }).id(group.id)
                        }
                    }.padding(12)
                }
                .task(id:store.navigationIntent?.id) {
                    guard let id = store.navigationIntent?.destination.selectedID else { return }
                    guard let group = taskGroups.first(where: { $0.contains(id) }) else { return }
                    await Task.yield();reader.scrollTo(group.id,anchor:.center)
                }
                }
            }
            if !store.recoveredPIDs.isEmpty { Text("等待上次自有生成进程安全退出…").foregroundStyle(.secondary).padding(20) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func stat(_ label: String, value: String, caption: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).foregroundStyle(color)
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var emptyQueue: some View {
        VStack(spacing: 15) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(Color.studioGold)
            Text("从一个镜头开始").font(.system(size: 16, weight: .medium))
            Text("导入现有镜头清单，或添加一条任务。\n先用合成验证查看进度与候选输出。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("添加合成验证任务") { store.add(.fixture(shot: store.state.jobs.count + 1, title: "日月轨迹 · 合成验证")) }
                .buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    @ViewBuilder private var inspector: some View {
        if let job = store.selected {
            VStack(alignment: .leading, spacing: 0) {
                if !store.navigationBackStack.isEmpty {
                    Button("返回结果",systemImage:"arrow.left") { _ = store.returnFromTaskNavigation() }
                        .buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.secondary).padding(.bottom,12)
                }
                HStack {
                    Text(job.shortID).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.studioGold)
                    Spacer()
                    StatusPill(status: job.status,title:job.displayStatusLabel)
                }.padding(.bottom, 10)
                Text(selectedGroup?.title ?? job.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).padding(.bottom, 7)
                if let group = selectedGroup, group.hasHistory {
                    Picker("任务版本", selection: Binding(get: { job.id }, set: { id in
                        _ = store.navigateToTask(id, from: navigationLocation)
                    })) {
                        ForEach(group.versions.reversed()) { version in
                            Text("第\(group.versionNumber(version.id))版 · " + (version.id == group.current.id ? "当前" : "历史") + " · " + version.displayStatusLabel)
                                .tag(version.id)
                        }
                    }.labelsHidden().accessibilityLabel("任务版本").accessibilityIdentifier("task-version.picker").padding(.bottom, 6)
                    HStack {
                        Button("全部 \(group.versions.count) 个版本", systemImage: "clock.arrow.circlepath") { inspectorTab = 2 }
                        Spacer(minLength: 4)
                        if job.id != group.current.id {
                            Button("回到当前版本") { _ = store.navigateToTask(group.current.id, from: navigationLocation) }
                        }
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.studioGold).padding(.bottom, 8)
                }
                if let issue = selectedGroup?.relationshipIssue {
                    Text(issue).font(.system(size: 10)).foregroundStyle(Color.orange).padding(.bottom, 8)
                }
                Text(job.segment + " · " + job.engine.label).font(.system(size: 9)).foregroundStyle(.secondary).padding(.bottom, 18)
                Picker("镜头详情", selection: $inspectorTab) { Text("详情").tag(0); Text("日志").tag(1); Text("历史").tag(2) }
                    .pickerStyle(.segmented).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if inspectorTab == 0 { detail(job) }
                        else if inspectorTab == 1 { logs(job) }
                        else { history(job) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                inspectorActions(job).padding(.top, 14)
            }.padding(20).background(palette.surface.opacity(0.65))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "viewfinder").font(.system(size: 27, weight: .light))
                Text("选择一个镜头").font(.system(size: 13, weight: .medium))
                Text("查看参考、参数与生成记录").font(.system(size: 10)).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func inspectorActions(_ job: ShotJob) -> some View {
        var primary: InspectorAction?
        var secondary: [InspectorAction] = []
        var caption: String?
        if job.h3Binding?.appFirstTask != nil,job.h3VideoRejection != nil,job.supersededBy == nil {
            secondary.append(InspectorAction(id:"face-fidelity",title:"人脸保真对照",icon:"person.crop.rectangle") { fidelityCandidate = job })
        }
        if store.canBindStaticInput(job.id) {
            secondary.append(InspectorAction(id:"bind-static-image",title:"绑定完整静态图",icon:"photo.badge.plus") { staticInputs = true })
        }
        if store.canRedoEntireShot(job.id) {
            secondary.append(InspectorAction(id:"redo-whole-shot",title:"整镜重做",icon:"arrow.counterclockwise.circle") {
                do { _ = try store.redoEntireShot(job.id,reason:"App 整镜重做操作，保留旧候选并撤销旧接受和下游依赖。",sourceReference:"AppUI_redo:" + UUID().uuidString);staticInputs = true }
                catch { store.notice = error.localizedDescription }
            })
        }
        if job.supersededBy == nil,job.h3Binding != nil,[JobStatus.completed,.failed,.cancelled,.interrupted].contains(job.status),job.h3QueuePlan != nil {
            secondary.append(InspectorAction(id:"reject-video",title:job.h3VideoRejection == nil ? "拒绝候选" : "拒绝原因与来源",icon:"xmark.circle",enabled:store.canRejectVideo(job.id)) { rejectingCandidate = job })
            secondary.append(InspectorAction(id:"redo-video",title:"重做这段",icon:"arrow.clockwise",enabled:store.canRedoVideo(job.id)) {
                Task { await store.redoVideo(job.id);if store.selected?.requiresNewStaticInput == true { staticInputs = true } }
            })
        }
        if job.status == .completed,job.supersededBy == nil,let plan = job.h3QueuePlan,job.h3Outcome?.technicalPass == true {
            primary = InspectorAction(id:"accept-video",title:job.h3VideoReview?.isTrustedAcceptance == true ? (plan.part < plan.partCount ? "继续下一段" : "已接受此候选") : (plan.part < plan.partCount ? "接受并继续下一段" : "接受此候选"),icon:"checkmark",enabled:store.canAcceptVideo(job.id) && (job.h3VideoReview?.isTrustedAcceptance != true || plan.part < plan.partCount)) {
                Task { await store.acceptVideoAndContinue(job.id) }
            }
            secondary.append(InspectorAction(id:"import-user-acceptance",title:"同步外部用户接受指令",icon:"text.bubble",enabled:store.canAcceptVideo(job.id)) {
                let panel = NSOpenPanel();panel.allowedContentTypes = [.json]
                panel.begin { response in if response == .OK,let url = panel.url { Task { do { try await store.importUserVideoAcceptance(url,id:job.id) } catch { store.notice = error.localizedDescription } } } }
            })
            caption = job.h3VideoRejection == nil ? "接受当前所选视频与端帧，一次记录并接续下一段；重做后的新候选独立接受。" : "候选已拒绝，旧验收不能放行续段。重做保留原视频；修订候选需重新绑定实际首图与提示词。"
        } else if store.hasAcceptanceRecoveryAction(job) {
            primary = InspectorAction(id:"rebind-acceptance-source",title:"恢复本段",icon:"arrow.clockwise",enabled:store.canRebindAcceptanceSource(job.id) || store.canResumeAcceptanceRebind(job.id)) {
                Task { await store.rebindAcceptanceSource(job.id) }
            }
            caption = "接受来源已补录；核对同一端帧，保留原接受与图审后继续，无需再次接受。"
        } else if job.status == .failed,job.shot == 35,job.h3QueuePlan?.part == 1,job.h3FirstProposal?.queueExecution != nil,job.attempts.isEmpty,job.h3Binding == nil {
            primary = InspectorAction(id:"revise-action",title:store.actionRevisionID == job.id ? "正在核对动作修订" : "修正动作并重新准备",icon:"pencil.and.outline",enabled:store.canReviseAction(job.id)) {
                Task { await store.reviseAction(job.id) }
            }
            caption = "按助手已核动作修订，保留旧失败与提示词；新画面检查后自动接续一次。"
        } else if job.h3FirstProposal != nil,job.status.isPending {
            primary = InspectorAction(id:"generate",title:job.h3AutomaticWorkflow == nil ? "开始生成 \(job.shortID) 第\(job.h3FirstProposal!.part)段" : "自动流程进行中",icon:"play.fill",enabled:store.canStartFirstWorkflow(job.id)) {
                Task { await store.startAuthorizedFirst(job.id) }
            }
            caption = "自动提取实际源帧、保留完整画面，检查通过后接续生成。"
            if job.h3FirstProposal?.input != nil,job.h3AutomaticWorkflow?.phase == "pixel_qa" {
                secondary.append(InspectorAction(id:"import-input-review",title:"导入输入图审…",icon:"checklist",enabled:store.canImportInputReview(job.id)) {
                    let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
                    panel.message = "选择已检查实际原图、归一图、动作参考与提示词的图审记录。App 会重新核对全部输入指纹。"
                    panel.begin { response in if response == .OK,let url = panel.url {
                        Task { do { try await store.importInputReview(url,id:job.id) } catch { store.notice = error.localizedDescription } }
                    } }
                })
            }
        } else if let plan = job.h3QueuePlan,job.status.isPending {
            primary = InspectorAction(id:"prepare-planned",title:"准备 \(job.shortID) 第\(plan.part)段",icon:"play.fill",enabled:store.canPreparePlannedJob(job.id)) {
                Task { await store.startPlannedJob(job.id) }
            }
            caption = plan.dependencyRequestID == nil ? "提取本段实际首帧；助手图审通过后自动生成。" : "须先有前段画面和精确端点审核；缺审核保持等待。"
        } else if job.h3ABConfiguration != nil, job.status.isPending {
            primary = InspectorAction(id: "generate", title: store.abWorkflowID == job.id ? "自动流程进行中" : "开始生成 \(job.shortID)", icon: "play.fill", enabled: store.canStartS41Workflow(job.id)) {
                Task { await store.startAuthorizedS41(job.id) }
            }
            caption = "自动处理输入、校验、生成并检查输出。"
            if job.h3Binding == nil {
                secondary.append(InspectorAction(id: "refresh", title: "核对更新配置", icon: "arrow.triangle.2.circlepath", enabled: !store.abConfigurationBusy) {
                    Task { await store.refreshS41Configuration(job.id) }
                })
            }
        } else if job.h3Binding != nil && job.status.isPending {
            primary = InspectorAction(id: "generate", title: "运行此单镜", icon: "play.fill", enabled: store.canRunH3(job.id)) { runH3FromUI(job) }
        }
        if job.externalHistory == nil && (job.status.isActive || job.status.isPending || store.actionRevisionID == job.id) {
            secondary.append(InspectorAction(id: "cancel", title: job.status == .cancelling ? "正在取消" : "取消任务", icon: "stop.circle", enabled: job.status != .cancelling) {
                cancelQueueTaskFromUI(job.id, store: store)
            })
        }
        if job.canRetryInApp {
            primary = InspectorAction(id: "retry", title: "重试", icon: "arrow.clockwise") { store.retry(job.id) }
        }
        if job.h3ABConfiguration != nil && (job.status.canRetry || job.h3InputPreparation?.status == "failed") {
            primary = InspectorAction(id: "new-retry", title: "新建重试任务", icon: "arrow.clockwise", enabled: store.singleGeneratorIdle) {
                Task { await store.createS41RetryTask(job.id) }
            }
            caption = "原任务的候选、参考图与日志继续保留。"
        }
        if let candidate = job.candidate {
            secondary.append(InspectorAction(id: "candidate", title: "查看候选目录", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate)])
            })
        }
        return InspectorActionBar(primary: primary, secondary: secondary, caption: caption)
    }
    private func detail(_ job: ShotJob) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let candidate = job.candidate, FileManager.default.fileExists(atPath: candidate) {
                CandidateVideoPreview(path:candidate,title:job.title).frame(height:145)
                Label(job.externalHistory.map { $0.userRequestedRedo == true ? "此前 CLI 生成 · 用户已拒收，要求重做" : ($0.userSelected ? "此前 CLI 生成 · 用户已选用" : (job.h3Outcome?.visualReview == "quality_unpassed" ? "技术完成 · 画面审查未过，待用户确认" : (job.h3Outcome?.technicalPass == true ? "此前 CLI 生成 · 技术通过，备选" : "此前 CLI 生成 · 待质检与用户确认"))) } ?? (job.engine == .h3 && job.h3Outcome == nil ? "已写出候选 · 技术检查待完成" : "候选输出 · 未纳入正式成片"), systemImage: job.engine == .h3 && job.h3Outcome == nil ? "clock" : "checkmark.shield")
                    .font(.system(size: 9)).foregroundStyle(job.engine == .h3 && job.h3Outcome == nil ? Color.studioGold : Color.studioTeal)
            } else if job.h3FirstProposal != nil {
                H3FirstReferences(job:job)
            } else if let binding = job.h3StaticBinding {
                AsyncPreviewImage(path:binding.primary.path,revision:binding.primary.sha256,scope:.abReference,fit:true).frame(height:146)
            } else if let plan = job.h3QueuePlan {
                H3QueuePlanDetail(plan:plan)
            } else if let configuration = job.h3ABConfiguration {
                H3ABReferences(configuration:configuration,preparation:job.h3InputPreparation,terminal:!job.status.isPending)
            } else {
                Thumbnail(path: job.reference, seed: job.shot).frame(height: 146).clipShape(RoundedRectangle(cornerRadius: 10))
                Label(job.reference == nil ? "尚未选择参考图" : "输入参考图", systemImage: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if job.candidate != nil || job.supersededBy != nil {
                let origin = ResultRouteOrigin.current(job)
                RedoTaskRouteCard(route:store.redoRoute(for:origin)) { target in openRedo(origin,target:target) }
            }
            if let last = job.h3FidelityChecks?.last {
                if let guidance = last.guidance { H3FidelityGuidanceCard(value:guidance) }
                else if last.status == "failed" { H3FidelityGuidanceCard(value:.executionFailure) }
                else if last.status == "completed" {
                    H3FidelityGuidanceCard(value:H3FidelityGuidance.make(.needsMoreReview,shot:job.shot,kind:last.kind))
                }
            }
            if let binding = job.h3StaticBinding { H3StaticBindingSummary(binding:binding) }
            if let configuration = job.h3ABConfiguration {
                if job.candidate != nil { H3ABReferences(configuration:configuration,preparation:job.h3InputPreparation,terminal:!job.status.isPending) }
                H3ABTaskTimeline(job:job)
            }
            if job.h3FirstProposal != nil {
                if let revision = job.h3FirstProposal?.queueExecution?.actionRevision {
                    VStack(alignment:.leading,spacing:6) {
                        Label("动作修订 r\(revision.number) · 原失败记录保留",systemImage:"clock.arrow.circlepath").font(.system(size:10,weight:.medium))
                        Text(revision.actionGoal).font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                }
                if job.candidate != nil { H3FirstReferences(job:job) }
                H3FirstTaskTimeline(job:job)
            }
            if let plan = job.h3QueuePlan {
                if job.status == .completed,job.h3Outcome?.technicalPass == true {
                    H3VideoReviewCard(job:job)
                } else if let request = plan.dependencyRequestID,let previous = store.currentPlannedJob(request) {
                    H3DependencyReviewCard(previous:previous,rawIndex:plan.dependencyRawIndex ?? 0)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("当前阶段")
                TimelineView(.periodic(from:.now,by:1)) { context in
                    ActivityStatusCard(value:store.activity(for:job,at:context.date))
                }
                if job.engine == .h3 {
                    if job.h3QueuePlan != nil,job.h3FirstProposal == nil {
                        Text("本条是已登记的短段计划，实际输入与检查尚未齐备；当前无法进入生成，不会使用旧参考图空跑。")
                            .font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                    } else if job.h3FirstProposal != nil {
                        Text("从实际母片帧开始，完整缩放与补边；检查通过后自动接续首帧生成，串行执行，取消保留预览和候选。")
                            .font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                    } else {
                    Text(job.h3ABConfiguration != nil ? "由 App 连续执行输入处理、自动检查、H3 生成与输出检查。A 接 port5，B 接 port6；串行执行，取消保留产物。" : (job.externalHistory != nil ? "来源：此前 CLI 生成。只读导入实际执行记录与原候选；未由 App 启动，不取得旧 PID，不取消、重投或修改正式成片。" : (job.h3Binding == nil ? "此镜头尚未绑定核准单镜。绑定后即可开始已授权任务，后续队列保持暂停。" : "已绑定单次任务；不自动重试或运行下一镜。失败或取消后需新授权任务。取消仅停止本应用启动的进程，保留候选和日志。")))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    if let outcome = job.h3Outcome { Text(job.externalHistory.map { $0.userRequestedRedo == true ? "用户已要求重做；旧片和执行记录保留，新任务另外登记，不自动重试或裁剪。" : ($0.userSelected ? "用户已选用；原记录的采用状态以用户最新决定为准。" : (outcome.visualReview == "quality_unpassed" ? "严格技术检查通过；画面审查未过，等待用户确认，不自动重试或裁剪。" : "严格技术验证通过；备选尚未采用。")) } ?? (outcome.simulated ? "CPU 模拟协议已验证，非真实 H3 输出。" : "自动技术检查完成；检查范围为帧数、尺寸、音视频解码与文件完整性。内容质量未自动判定。"))
                        .font(.system(size: 10)).foregroundStyle(Color.studioTeal) }
                    else if job.h3Binding?.executionAuthorized == false { Text("当前契约尚未授权本次真实生成。").font(.system(size: 10)).foregroundStyle(Color.studioGold) }
                    if let configuration = job.h3ABConfiguration,job.status.isPending {
                        ForEach(configuration.blockers.filter { !$0.contains("归一图尚未人工检查") },id:\.self) { reason in Label(reason,systemImage:"clock").font(.system(size:10)).foregroundStyle(Color.studioGold) }
                    }
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(palette.raised.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("生成参数")
                valueRow("分辨率", job.parameters.resolutionLabel)
                valueRow("帧数 / 步数", "\(job.parameters.frames.map(String.init) ?? "—") / \(job.parameters.steps.map(String.init) ?? "—")")
                valueRow("目标时长", String(format: "%.2f 秒", job.requestedDuration))
                if let proposal = job.h3FirstProposal {
                    valueRow("实际源帧","全局 \(proposal.sourceFrameIndex) · 镜头内 \(proposal.sourceLocalFrameIndex)")
                    valueRow("原生生成","\(proposal.profile.frames) 帧 · \(proposal.profile.fps) fps")
                    valueRow("首段选择","raw[\(proposal.selectedRawStart),\(proposal.selectedRawEnd)) · \(proposal.targetFrames) 帧")
                    Text("原生 \(proposal.profile.frames) 帧先完整保存。所选窗口和 raw\(proposal.selectedRawEnd-1) 端点检查完成后，后续段再单独接续；当前不会裁剪或替换正式成片。")
                        .font(.system(size:9)).foregroundStyle(.secondary).lineSpacing(3)
                }
                if let configuration = job.h3ABConfiguration {
                    valueRow("原生生成",String(format:"73 帧 · 24 fps · %.3f 秒",configuration.nativeDuration))
                    valueRow("成片目标","72 帧 · 24 fps · 3.000 秒")
                    valueRow("末图锚点","raw72 · PTS 3.000 秒")
                    valueRow("原生 73 帧试跑",job.h3Outcome.map { $0.simulated ? "仅 CPU 协议验证" : ($0.technicalPass ? "本次真实技术通过" : "待通过") } ?? "源码支持，真实结果待核")
                    Text("原生视频先保持完整 73 帧。质检与用户确认后，另建 App 导出任务删一张内部低动作帧，保存完整映射，保留 raw0 与 raw72。当前没有裁剪或导出。").font(.system(size:9)).foregroundStyle(.secondary).lineSpacing(3)
                }
                valueRow("本次耗时", job.elapsedLabel)
                valueRow("模型", job.parameters.model)
                if let source=job.externalHistory {
                    valueRow("任务来源","此前 CLI 生成")
                    valueRow("实际开始",job.startedAt?.formatted(date:.abbreviated,time:.standard) ?? "未知")
                    valueRow("原生结束",job.endedAt?.formatted(date:.abbreviated,time:.standard) ?? "尚未结束")
                    valueRow("技术检查",source.technicalSHA256 == nil ? "待完成" : "已通过")
                    valueRow("画面审查",job.h3Outcome?.visualReview == "quality_unpassed" ? "未通过" : source.userSelected ? "用户已接受" : "待确认")
                    valueRow("用户采用",source.userRequestedRedo == true ? "已拒收 / 要求重做" : source.userSelected ? "已选用" : "备选 / 待确认")
                    if let reason=source.userReason { valueRow("用户说明",reason) }
                    valueRow("已整合成片",source.integratedIntoMaster == true ? "父任务记录：已整合" : "未整合")
                }
                if !job.parameters.verified { Text("导入参数仅供参考，实际值待引擎确认。").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            if let peaks = job.attempts.last?.peaks, peaks.samples > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(job.externalHistory == nil ? "本次资源峰值 · \(peaks.samples) 次采样" : "此前 CLI 报告的资源峰值")
                    valueRow("应用内存占用", formatMB(peaks.appFootprintMB))
                    valueRow("生成进程 RSS", formatMB(peaks.workerRSSMB))
                    valueRow(job.externalHistory == nil ? "系统 CPU" : "CLI 进程 CPU", (job.externalHistory?.reportedCPUPercent ?? peaks.systemCPU).map { String(format:"%.1f%%",$0) } ?? "不可用")
                }
            }
            if let error = job.error {
                VStack(alignment: .leading, spacing: 7) {
                    Label("需要处理", systemImage: "exclamationmark.circle").font(.system(size: 11, weight: .medium))
                    Text(error).font(.system(size: 10)).textSelection(.enabled).lineSpacing(3)
                }.foregroundStyle(Color.red.opacity(0.8)).padding(12).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            DisclosureGroup("动作提示词") {
                Text(job.prompt.isEmpty ? "未提供" : job.prompt).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).lineSpacing(4).padding(.top, 8)
            }.font(.system(size: 11, weight: .medium))
        }
    }
    private func logs(_ job: ShotJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保留原始引擎事件与错误；进度以事件为准。").font(.system(size: 10)).foregroundStyle(.secondary)
            if job.logTail.isEmpty { Text("暂无日志").foregroundStyle(.secondary).padding(.vertical, 25) }
            else { Text(job.logTail.suffix(100).joined(separator: "\n\n")).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).lineSpacing(3) }
            if let attempt = job.attempts.last {
                Button("打开完整日志") { NSWorkspace.shared.open(job.externalHistory?.nativeLog.map { URL(fileURLWithPath:$0) } ?? URL(fileURLWithPath: attempt.directory).appendingPathComponent("engine.log")) }.buttonStyle(.bordered)
            }
        }
    }
    private func history(_ job: ShotJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let group = selectedGroup, group.hasHistory {
                TaskVersionHistory(group: group, selectedID: job.id) { id in
                    _ = store.navigateToTask(id, from: navigationLocation)
                }
                Divider()
                Text("第\(group.versionNumber(job.id))版的执行记录").font(.system(size: 11, weight: .medium))
            }
            if let revision = job.h3FirstProposal?.queueExecution?.actionRevision {
                VStack(alignment:.leading,spacing:8) {
                    Text("动作修订 r\(revision.number)").font(.system(size:12,weight:.medium))
                    Text("同一任务身份。修订前失败、旧提示词、提案与失败画面检查均保留；旧检查不能放行新修订。")
                        .font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                    Button("查看修订历史目录",systemImage:"folder") { NSWorkspace.shared.open(URL(fileURLWithPath:revision.directory)) }
                        .buttonStyle(.bordered).controlSize(.small)
                    let origin = ResultRouteOrigin(jobID:job.id,revision:revision.number-1,frozenStateSHA256:revision.previousStateSHA256)
                    RedoTaskRouteCard(route:store.redoRoute(for:origin)) { target in openRedo(origin,target:target) }
                }.padding(12).background(palette.raised.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius:9))
            }
            Text(job.externalHistory == nil ? "每次重试使用新的候选目录，已完成输出持续保留。" : "此前 CLI 的真实执行记录。只读导入，不会在 App 中重新执行。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            if job.attempts.isEmpty { Text("尚未执行").foregroundStyle(.secondary).padding(.vertical, 25) }
            ForEach(job.attempts.reversed()) { attempt in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("尝试 \(attempt.number)").fontWeight(.medium); Spacer(); StatusPill(status: attempt.status) }
                    Text(attempt.startedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 9)).foregroundStyle(.secondary)
                    valueRow("进程 RSS 峰值", formatMB(attempt.peaks.workerRSSMB))
                    valueRow("同期整机 GPU 采样峰值", attempt.peaks.systemGPU.map { String(format: "%.0f%%", $0) } ?? "不可用")
                    Button("查看候选目录") { NSWorkspace.shared.open(URL(fileURLWithPath: attempt.directory)) }.buttonStyle(.bordered).controlSize(.small)
                }.padding(12).background(palette.raised.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }
    private func sectionLabel(_ label: String) -> some View { Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 16); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.system(size: 10))
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.studioTeal).frame(width: 5, height: 5)
            Text("本地工作区"); Text("·"); Text("并发 1")
            Spacer()
            if telemetry.enabled {
                Button { metrics = true; models = false } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chart.xyaxis.line")
                        Text("CPU " + (telemetry.latest?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"))
                        Text("GPU " + (telemetry.latest?.gpu?.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—"))
                        Text("应用 " + formatMB(telemetry.latest?.appFootprintMB))
                    }
                }.buttonStyle(.plain).help("查看性能监控；GPU 为整机驱动上报使用率，缺值显示 —")
            } else { Text("性能监控已关闭") }
        }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 23).padding(.vertical, 12)
            .background(palette.surface.opacity(0.6)).overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
    }
    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(size: 10)).foregroundStyle(color).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 23).padding(.vertical, 10)
    }
    private func importManifest() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "选择现有镜头 JSON；只读导入，输出使用独立候选目录。"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do { try store.importManifest(url) } catch { store.notice = error.localizedDescription }
            }
        }
    }
    private func importH3Job() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "选择新的已核准单镜 job.json。已领取的任务不会重跑，导入不会启动生成。"
        panel.begin { response in
            if response == .OK, let url = panel.url { do { try store.importH3Job(url) } catch { store.notice = error.localizedDescription } }
        }
    }
    private func createS41Known() {
        Task { do { _ = try await store.importS41Configuration(H3ABConfiguration.knownPath) } catch { store.notice = error.localizedDescription } }
    }
    private func importS41Configuration() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.message = "选择已核 S41 A/B 独立配置。App 保存任务与素材指纹；导入不会启动生成。"
        panel.begin { response in
            guard response == .OK,let url = panel.url else { return }
            Task { do { _ = try await store.importS41Configuration(url) } catch { store.notice = error.localizedDescription } }
        }
    }
    private func importH3History() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        panel.message="选择恢复目录 candidates 下的 job.json；只读导入历史，不执行命令。"
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            let root=URL(fileURLWithPath:store.locations.modelStatusRoot)
            Task {
                do {
                    let record=try await Task.detached(priority:.utility) { try H3HistoryImporter.load(url,restoreRoot:root) }.value
                    _ = try store.importExternalHistory([record])
                } catch { store.notice=error.localizedDescription }
            }
        }
    }
    private func runH3FromUI(_ job: ShotJob) {
        guard let binding = job.h3Binding, store.canRunH3(job.id) else { return }
        store.startH3(job.id, approval: .userConfirmed(binding.jobSHA256))
    }
}

struct ShotRow: View {
    var job: ShotJob
    var title: String
    var versionCount: Int
    var relationshipIssue: String?
    var selected: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var select: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var cancel: () -> Void
    var retry: () -> Void
    var drop: (UUID) -> Bool
    @State private var dropTarget = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 8) {
            if job.status.isPending {
                selection.onDrag { NSItemProvider(object: job.id.uuidString as NSString) }
            } else { selection }
            if job.status != .completed {
                HStack(spacing: 6) {
                    if job.status == .blocked { Text(job.h3QueuePlan != nil ? job.displayStatusLabel : job.h3ABConfiguration != nil ? "开始后自动执行" : job.h3Binding == nil ? "等待单镜绑定" : job.h3Binding?.executionAuthorized == true ? "就绪可生成" : "本次尚未授权").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Button("上移", systemImage: "arrow.up", action: moveUp).disabled(!canMoveUp)
                        .accessibilityLabel("上移：\(job.title)")
                    Button("下移", systemImage: "arrow.down", action: moveDown).disabled(!canMoveDown)
                        .accessibilityLabel("下移：\(job.title)")
                    Button("重试", systemImage: "arrow.clockwise", action: retry).disabled(!job.canRetryInApp)
                        .accessibilityLabel("重试：\(job.title)")
                    Button(action: cancel) {
                        Text(job.status == .cancelled ? "已取消" : job.status == .cancelling ? "取消中…" : "取消")
                            .frame(width: 47)
                    }.disabled(!job.canCancelInApp)
                        .accessibilityLabel("取消：\(job.title)")
                }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 9))
            }
        }.padding(11).background(dropTarget && job.status.isPending ? Color.studioGold.opacity(0.17) : selected ? Color.studioGold.opacity(scheme == .dark ? 0.1 : 0.09) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(dropTarget || selected ? Color.studioGold.opacity(0.26) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .onDrop(of: [UTType.text], isTargeted: $dropTarget) { providers in
                guard job.status.isPending, let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let text = item as? String, let sourceID = UUID(uuidString: text) else { return }
                    DispatchQueue.main.async { _ = drop(sourceID) }
                }
                return true
            }
    }
    private var selection: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                Thumbnail(path: job.reference, seed: job.shot).frame(width: 61, height: 43).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(job.shortID).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.studioGold)
                        Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    Text(job.engine == .fixture ? "合成验证 · 48 帧 · CPU" : job.segment).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    if versionCount > 1 {
                        Text("当前第\(versionCount)版 · 历史 \(versionCount - 1) 版").font(.system(size: 9)).foregroundStyle(Color.studioGold)
                    }
                    if relationshipIssue != nil { Text("重做关系待核对").font(.system(size: 9)).foregroundStyle(Color.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    StatusPill(status: job.status,title:job.displayStatusLabel)
                    if let progress = job.progress { Text(progress.label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                }
                Text(job.elapsedLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
        }.buttonStyle(.plain)
            .accessibilityLabel("\(job.shortID)，\(title)，当前第\(versionCount)版，\(job.engine.label)，\(job.displayStatusLabel)，\(job.progress?.label ?? job.stage)")
            .accessibilityIdentifier("task-row.current.\(job.id.uuidString)")
    }
}

struct StatusPill: View {
    var status: JobStatus
    var title: String? = nil
    var body: some View {
        Label(title ?? status.label, systemImage: status.icon).font(.system(size: 9, weight: .medium)).foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 4).background(status.color.opacity(0.08)).clipShape(Capsule())
    }
}

struct Thumbnail: View {
    var path: String?
    var seed: Int
    var body: some View {
        GeometryReader { geo in
            if let path {
                AsyncPreviewImage(path:path).frame(width:geo.size.width,height:geo.size.height)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.11, green: 0.2, blue: 0.28), Color(red: 0.05, green: 0.09, blue: 0.14)], startPoint: .top, endPoint: .bottom)
                    Canvas { context, size in
                        var ridge = Path(); ridge.move(to: CGPoint(x: 0, y: size.height))
                        for x in stride(from: 0.0, through: size.width, by: 4) {
                            let y = size.height * (0.57 + 0.11 * sin(x / size.width * 10 + Double(seed)))
                            ridge.addLine(to: CGPoint(x: x, y: y))
                        }
                        ridge.addLine(to: CGPoint(x: size.width, y: size.height)); ridge.closeSubpath()
                        context.fill(ridge, with: .color(Color(red: 0.15, green: 0.29, blue: 0.32)))
                        let radius = size.height * 0.065
                        context.fill(Path(ellipseIn: CGRect(x: size.width * 0.72, y: size.height * 0.21, width: radius * 2, height: radius * 2)), with: .color(.studioGold.opacity(0.8)))
                    }
                    if geo.size.height > 100 { Text(path == nil ? "未选择参考图" : "参考图不可读").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12) }
                }
            }
        }.accessibilityLabel(path == nil ? "未选择参考图" : "镜头参考图")
    }
}

struct CandidatePlayer: NSViewRepresentable {
    let path: String
    final class Coordinator { var path = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        // Use AppKit AVPlayerView directly: this Mac's _AVKit_SwiftUI runtime
        // aborts while instantiating VideoPlayer's generic superclass metadata
        // when built with Xcode 27. AVPlayerView avoids that overlay boundary.
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.setAccessibilityLabel("候选视频预览")
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.path != path else { return }
        view.player?.pause()
        view.player = AVPlayer(url: URL(fileURLWithPath: path))
        context.coordinator.path = path
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        // AVKit updates its control focus chain when the player is detached.
        // On macOS 27 doing this while SwiftUI invalidates the inspector's
        // AttributeGraph reads already destroyed focus geometry and aborts.
        // Keep the view alive until this removal transaction has completed.
        DispatchQueue.main.async { view.player = nil }
    }
}

struct AddJobView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var shot = 1
    @State private var duration = 5.167
    @State private var engine: EngineKind = .h3
    @State private var reference: String?
    @State private var injectFailure = false
    @State private var plannedID = ""
    private var planned: [ShotJob] { store.state.jobs.filter { $0.supersededBy == nil && $0.externalHistory == nil && $0.h3QueuePlan != nil && $0.attempts.isEmpty && $0.h3Binding == nil } }
    private var plannedJob: ShotJob? { planned.first(where:{ $0.id.uuidString == plannedID }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("添加生成任务").font(.system(size: 21, weight: .semibold)); Spacer(); Button("取消") { dismiss() }.buttonStyle(.plain) }
            Text("每个镜头独立记录。输出先作为候选，串行执行。").font(.system(size: 11)).foregroundStyle(.secondary)
            if engine == .h3 {
                Picker("已登记镜头段",selection:$plannedID) {
                    Text("选择镜头段").tag("")
                    ForEach(planned) { job in Text("\(job.shortID) · 第\(job.h3QueuePlan!.part)/\(job.h3QueuePlan!.partCount)段").tag(job.id.uuidString) }
                }.onChange(of:plannedID) { _,_ in if let job = plannedJob { shot = job.shot;prompt = job.prompt } }
            } else {
            TextField("镜头名称", text: $title).textFieldStyle(.roundedBorder)
            HStack { Stepper("镜头 \(shot)", value: $shot, in: 1...10000); Spacer(); Text("目标时长"); TextField("秒", value: $duration, format: .number.precision(.fractionLength(2))).frame(width: 60).textFieldStyle(.roundedBorder); Text("秒") }
                .font(.system(size: 11))
            }
            HStack(spacing: 15) {
                Thumbnail(path: reference, seed: shot).frame(width: 117, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Text(reference.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "参考图").font(.system(size: 11)).lineLimit(1)
                    Button("选择图片…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
                        panel.begin { response in if response == .OK { reference = panel.url?.path } }
                    }.buttonStyle(.bordered)
                }
            }
            Text("动作提示词").font(.system(size: 11, weight: .medium))
            TextEditor(text: $prompt).font(.system(size: 12)).frame(height: 90).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            Picker("生成器", selection: $engine) { ForEach(EngineKind.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            Text(engine == .h3 ? "将完整图片正式绑定已登记的镜头窗口。App 保存原图并用 CPU 缩放补边，助手检查后自动接续一次；旧 QA 不沿用。" : "仅生成 2 秒程序化测试视频，不使用模型。进度来自实际写出的帧。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if engine == .fixture { Toggle("注入一次失败，用于验证重试", isOn: $injectFailure).font(.system(size: 11)) }
            HStack { Spacer(); Button(engine == .h3 ? "绑定完整图并准备" : "添加到队列") {
                if engine == .h3 {
                    guard let job = plannedJob,let reference else { return }
                    Task {
                        do {
                            let url = URL(fileURLWithPath:reference),text = prompt
                            let asset = try await Task.detached(priority:.utility) { try H3StaticAsset.selected(url,shot:job.shot,motion:text) }.value
                            _ = try await store.bindStaticInput(job.id,primary:asset,prompt:text,sourceReference:"AppUI_existing_material:" + UUID().uuidString)
                            dismiss()
                        } catch { store.notice = error.localizedDescription }
                    }
                    return
                }
                var job = ShotJob.fixture(shot: shot, title: title, failure: injectFailure)
                job.reference = reference
                if !prompt.isEmpty { job.prompt = prompt }
                store.add(job); dismiss()
            }.buttonStyle(StudioPrimaryButtonStyle()).disabled(engine == .h3 ? reference == nil || prompt.utf8.count < 12 || (plannedJob.map { !store.canBindStaticInput($0.id) } ?? true) : title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !duration.isFinite || duration <= 0 || duration > 600).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 460).onAppear {
            plannedID = planned.first(where:{ $0.id == store.selectedID })?.id.uuidString ?? planned.first?.id.uuidString ?? ""
            if let job = plannedJob { shot = job.shot;prompt = job.prompt }
        }
    }
}

func formatMB(_ value: Double?) -> String {
    guard let value else { return "不可用" }
    return value >= 1024 ? String(format: "%.2f GB", value / 1024) : String(format: "%.1f MB", value)
}

struct PerformanceView: View {
    @ObservedObject var monitor: TelemetryMonitor
    @ObservedObject var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                HStack {
                    Label("低开销采样", systemImage: "leaf").foregroundStyle(Color.studioTeal)
                    Spacer()
                    Picker("采样间隔", selection: Binding(get: { store.state.samplingInterval }, set: { store.configureMonitoring(enabled: store.state.monitoring, interval: $0) })) {
                        Text("2 秒").tag(2.0); Text("5 秒").tag(5.0); Text("10 秒").tag(10.0)
                    }.frame(width: 155).disabled(!monitor.enabled)
                    Toggle("监控", isOn: Binding(get: { store.state.monitoring }, set: { store.configureMonitoring(enabled: $0, interval: store.state.samplingInterval) })).toggleStyle(.switch).controlSize(.small)
                }.font(.system(size: 11))
                HStack(spacing: 12) {
                    metric("系统 CPU", value: monitor.latest?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", subtitle: "所有核心平均 · 采样间隔内")
                    metric("应用内存", value: formatMB(monitor.latest?.appFootprintMB), subtitle: "本应用 physical footprint")
                    metric("生成进程", value: formatMB(monitor.latest?.workerRSSMB), subtitle: "自建 worker + 封装进程 RSS")
                    metric("磁盘可用", value: monitor.latest?.diskFreeGB.map { String(format: "%.1f GB", $0) } ?? "不可用", subtitle: "候选目录所在卷")
                }
                GPUUsageView(readings: monitor.samples.compactMap(\.gpu), enabled: monitor.enabled,
                    interval: store.activeJob?.engine == .h3 ? max(10, monitor.interval) : monitor.interval)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("系统 CPU").font(.system(size: 13, weight: .medium)); Spacer(); Text("最近 \(monitor.samples.count) 次采样").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Chart(monitor.samples) { sample in
                        if let cpu = sample.cpuPercent {
                            AreaMark(x: .value("时间", sample.timestamp), y: .value("CPU", cpu)).foregroundStyle(LinearGradient(colors: [.studioGold.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("时间", sample.timestamp), y: .value("CPU", cpu)).foregroundStyle(Color.studioGold).lineStyle(StrokeStyle(lineWidth: 1.8))
                        }
                    }.chartYScale(domain: 0...100).chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.frame(height: 170)
                    if !monitor.enabled { Text("监控已关闭。图中保留的是历史采样。 ").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(18).background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    metric("系统内存估计", value: formatMB(monitor.latest?.systemUsedMB), subtitle: "活跃 + 非活跃 + wired + 压缩页")
                    metric("内存压力", value: monitor.pressure, subtitle: "系统压力事件监听；初始值未知")
                    metric("采样自身耗时", value: String(format: "%.3f ms", monitor.averageSamplingMilliseconds), subtitle: "平均单次采样壁钟耗时")
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("指标口径").font(.system(size: 12, weight: .medium))
                    Text("CPU 为整机所有核心的平均使用率。应用内存为本应用的物理占用；生成进程是应用自己启动的进程 RSS 总和，两者口径不同。系统内存为页计数估计，可能与活动监视器不同。\n低频采样可能错过短时峰值，每任务记录的是采样峰值。权限拒绝或接口不可用时保留缺值。GPU 来自 IORegistry 的 Device Utilization %，为整机驱动上报，统计窗口由驱动决定，无法单独归属本任务。GPU 共享内存来自 In use system memory，与系统内存共用，不能当作独立显存或相加。GPU 至少每 5 秒读取一次，H3 执行中至少 10 秒；缺值显示 —，曲线断开。温度和功耗当前不可用。严重内存压力会暂停后续队列，默认并发始终为 1。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(5)
                    Button("导出任务参数与资源记录…") {
                        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "镜生H3-任务资源记录.json"
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                do { try store.exportRecords(to: url) } catch { store.notice = error.localizedDescription }
                            }
                        }
                    }.buttonStyle(.bordered).padding(.top, 5)
                }
            }
        }
    }
    private func metric(_ label: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(subtitle).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct OrbView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var telemetry: TelemetryMonitor
    @ObservedObject var readiness: ModelReadinessMonitor
    @ObservedObject var hover: OrbHoverState
    var activate: () -> Void
    @State private var windowVisible = false
    var body: some View {
        TimelineView(FocusVisibilityTimelineSchedule(isVisible:windowVisible)) { context in
            let focus = store.executionFocus(at:context.date)
            content(focus.current?.activity ?? focus.orbIdleActivity,focus:focus)
        }
        .background(WindowVisibilityProbe { windowVisible = $0 }.frame(width:0,height:0))
    }
    private func content(_ activity: ActivityPresentation,focus: ExecutionFocusProjection) -> some View {
        HStack(spacing:12) {
            if hover.visible {
                VStack(alignment:.trailing,spacing:3) {
                    Text(focus.orbCurrent)
                        .font(.system(size:10,weight:.medium)).lineLimit(1)
                    Text(activity.progress?.label ?? activity.stage).font(.system(size:8)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    Text(focus.orbNext).font(.system(size:8)).foregroundStyle(Color.studioTeal.opacity(0.9)).lineLimit(1).help(focus.orbNext)
                    if telemetry.enabled {
                        Text("整机 GPU " + (telemetry.latest?.gpu?.utilizationPercent.map { String(format:"%.0f%%",$0) } ?? "—") + " · " + activity.elapsed)
                            .font(.system(size:8,design:.monospaced)).foregroundStyle(Color.studioTeal).lineLimit(1)
                    } else { Text("已用 " + activity.elapsed).font(.system(size:8)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                }.padding(7).background(Color(red:0.08,green:0.1,blue:0.13).opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius:12)).transition(.opacity).frame(width:162)
            } else { Spacer().frame(width:162) }
            ZStack {
                Circle().fill(Color(red:0.08,green:0.1,blue:0.13)).overlay(Circle().stroke(.white.opacity(0.09),lineWidth:1))
                Circle().stroke(Color.studioGold.opacity(0.12),lineWidth:2.5).padding(6)
                if let progress = activity.progress {
                    Circle().trim(from:0,to:progress.fraction).stroke(activity.tone.color,style:StrokeStyle(lineWidth:2.5,lineCap:.round)).rotationEffect(.degrees(-90)).padding(6)
                } else if focus.current == nil,readiness.phase == .ready,readiness.snapshot?.isDownloading == true,let fraction = readiness.fraction {
                    Circle().trim(from:0,to:fraction).stroke(Color.studioGold.opacity(0.75),style:StrokeStyle(lineWidth:2.5,lineCap:.round)).rotationEffect(.degrees(-90)).padding(6)
                }
                VStack(spacing:4) {
                    Image(systemName:activity.symbol).font(.system(size:17,weight:.light)).foregroundStyle(activity.tone == .waiting ? Color.studioGold : activity.tone.color)
                    Text(activity.shortState).font(.system(size:9,weight:.medium)).foregroundStyle(.white.opacity(0.85))
                }
                if store.pendingCount > 0 {
                    Text("\(store.pendingCount)").font(.system(size:8,weight:.semibold,design:.monospaced)).padding(4).background(Color.studioGold).foregroundStyle(.black).clipShape(Circle()).offset(x:24,y:-24)
                }
            }.frame(width:70,height:70).shadow(color:.black.opacity(0.2),radius:10,y:5)
                .help("镜生 H3 · " + focus.orbCurrent + " · " + focus.orbNext + " · " + activity.state + " · " + activity.stage + " · " + activity.lastProgress + (activity.heartbeat.map { " · " + $0 } ?? "") + " · 点击展开，拖动移动")
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("镜生 H3 悬浮球，" + focus.orbCurrent + "，" + focus.orbNext + "，" + activity.state + "，" + activity.stage + "，已用" + activity.elapsed + "，" + activity.lastProgress)
                .accessibilityAddTraits(.isButton).accessibilityAction { activate() }
        }.padding(12).foregroundStyle(.white).frame(width:268,height:94)
    }
}
