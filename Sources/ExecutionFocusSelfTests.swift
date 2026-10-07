import Foundation
import SwiftUI
import AppKit

@MainActor enum ExecutionFocusSelfTests {
    static let hashA = String(repeating:"a",count:64),hashB = String(repeating:"b",count:64)
    static func planned(shot: Int,priority: Int,part: Int = 1,dependency: String? = nil) -> ShotJob {
        var job = ShotJob(shot:shot,segment:"s\(shot)-p\(part)",title:"CPU 协议测试",prompt:"fixture prompt only",requestedDuration:3.5,engine:.h3,status:.blocked)
        job.h3QueuePlan = .init(requestID:"fixture-S\(shot)-p\(part)",manifestSHA256:hashA,shot:shot,part:part,partCount:3,
            priority:priority,actionGoal:"fixture only",identityReferencePath:"/tmp/declared-identity.png",identityReferenceSHA256:hashA,
            identityReferenceMatches:true,sourceMediaPath:dependency == nil ? "/tmp/declared-media.mp4" : nil,
            sourceMediaSHA256:hashA,sourceGlobalFrameIndex:dependency == nil ? 24 : nil,dependencyRequestID:dependency,dependencyRawIndex:dependency == nil ? nil : 83,
            promptPath:"/tmp/declared-prompt.txt",promptSHA256:hashA,profile:.s19First,seed:1,selectedRawStart:0,selectedRawEnd:84,destinationStart:0,destinationEnd:84)
        return job
    }
    static func revised(_ job: ShotJob,number: Int,previousHash: String) -> ShotJob {
        var result = job
        let revision = H3ActionRevision(number:number,actionGoal:"CPU fixture action revision",requestSourcePath:"/tmp/declared-request.json",requestSHA256:hashA,
            directory:"/tmp/declared-r\(number)",promptSHA256:hashB,previousProposalPath:"/tmp/declared-proposal.json",previousProposalSHA256:hashA,
            previousPromptSHA256:hashA,previousReviewSHA256:hashA,previousStateSHA256:previousHash)
        let source = H3QueueExecutionSource(appJobID:job.id,appWorkspace:"/tmp/declared-workspace",plan:job.h3QueuePlan!,sourceBytes:1,sourceFrames:48,
            sourceWidth:384,sourceHeight:216,sourceFPS:24,actionRevision:revision)
        result.h3FirstProposal = .init(sourcePath:"/tmp/declared-proposal.json",sourceSHA256:hashA,proposalID:"fixture",shot:job.shot,part:1,
            sourceMediaPath:"/tmp/declared.mp4",sourceMediaSHA256:hashA,sourceMediaBytes:1,sourceMediaFrames:48,sourceWidth:384,sourceHeight:216,
            sourceFPS:24,sourceFrameIndex:24,sourceLocalFrameIndex:24,profile:.s19First,selectedRawStart:0,selectedRawEnd:84,destinationGlobalStart:0,
            destinationGlobalEnd:84,seed:1,promptPath:"/tmp/declared.txt",promptSHA256:hashB,prompt:"CPU fixture",helperPath:"/tmp/no-helper",helperSHA256:hashA,
            libraryPath:"/tmp/no-library",librarySHA256:hashA,workDirectory:"/tmp/declared-workspace",launchAuthorized:true,queueExecution:source)
        return result
    }
    static func projection(_ jobs: [ShotJob],workflow: UUID? = nil,paused: Bool = false,idle: Bool = true,wait: String? = nil) -> ExecutionFocusProjection {
        ExecutionFocusProjector.project(jobs:jobs,ownedWorkflowID:workflow,preparationID:workflow,resourceIdle:idle,globalWait:wait,queuePaused:paused,
            now:Date(timeIntervalSince1970:1100),reviewExists:{ _ in false },alreadyDispatched:{ _ in false })
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        var store: TaskStore?
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let a = ShotJob.fixture(shot:1,title:"first"),b = ShotJob.fixture(shot:2,title:"second")
            try check("空闲不冒用所选候选",projection([a,b]).current == nil,"only owned active work or observed execution can occupy Current")
            var active = a;active.status = .running;active.stage = "采样生成";active.startedAt = Date(timeIntervalSince1970:1000)
            active.progress = .init(completed:2,total:4,unit:"步");active.executionActivity = .init(stage:active.stage,at:Date(timeIntervalSince1970:1000))
            let p = projection([active,b],paused:true,idle:false)
            try check("当前活动唯一且计数真实",p.current?.job.id == a.id && p.current?.activity.progress?.completed == 2 && p.conflictingActiveRecords == 1,"no percent from elapsed time")
            try check("活动期间保留真实下一项",p.next?.job.id == b.id && p.next?.resourceWait != nil,"resource lease does not become an input blocker")
            try check("暂停仅标注后续队列",p.current?.mode == .generation && p.next?.stateLabel.contains("队列已暂停") == true,"current worker stays active")
            var finished = active;finished.status = .completed;finished.endedAt = Date(timeIntervalSince1970:1080)
            try check("完成后当前与下一项转移",projection([finished,b]).current == nil && projection([finished,b]).next?.job.id == b.id,"terminal candidate is never Current")
            var blocked = planned(shot:19,priority:0,part:2,dependency:"missing-predecessor")
            let ready = planned(shot:35,priority:1)
            let head = projection([blocked,ready])
            try check("受阻队首不冒充下一项",head.next?.job.id == ready.id && head.waitingJob == nil,"same intrinsic readiness as H3 planned preparation")
            let waiting = projection([blocked])
            try check("全受阻时显式无就绪项",waiting.next == nil && waiting.waitingJob?.id == blocked.id && waiting.waitingReason?.contains("缺失") == true,"waiting conditions are distinct from execution")
            blocked.requiresNewStaticInput = true;blocked.h3QueuePlan?.dependencyRequestID = nil
            try check("新首图缺失优先解释",projection([blocked]).waitingReason == "等待绑定新的完整首图","no old mother-frame fallback")
            try check("H3优先级排序不依赖视图筛选",projection([ready,planned(shot:14,priority:0)]).next?.job.shot == 14,"priority and part match dispatcher")
            try check("队列重排实际改变下一项",projection([b,a]).next?.job.id == b.id,"fixture FIFO uses persisted queue order")
            var preparing = ready;preparing.h3AutomaticWorkflow = .init(status:"running",phase:"static_image_preparation",startedAt:Date(),automaticContinuationAuthorized:true)
            try check("CPU准备不标为GPU生成",projection([preparing],workflow:preparing.id,idle:false).current?.mode == .preparation,"resource ownership is typed")
            preparing.h3AutomaticWorkflow?.status = "waiting";preparing.h3AutomaticWorkflow?.phase = "pixel_qa"
            try check("助手图审等待不是当前执行",projection([preparing],workflow:preparing.id).current == nil,"no active ring while waiting for input QA")
            let fault = projection([a],wait:"工作区无法保存")
            try check("全局保存故障不伪称可启动",fault.current == nil && fault.next?.resourceWait == "工作区无法保存","ready input and blocked resources are separate")
            try check("悬浮球复用当前和下一项",p.orbCurrent.contains("S01") && p.orbNext.contains("S02") && waiting.orbCurrent == "当前无执行任务","no selected-row fallback")
            for mode in [ExecutionFocusMode.idle,.preparation,.observed,.cancelling] {
                try check("\(mode.rawValue)停止流光",!FocusMotionPolicy.shouldAnimate(mode:mode,reduceMotion:false,windowVisible:true),"only owned generation animates")
            }
            try check("真实执行可轻微呼吸",FocusMotionPolicy.shouldAnimate(mode:.generation,reduceMotion:false,windowVisible:true),"low-amplitude 4s breath and 10s gradient cycle")
            try check("减少动态效果禁用动画",!FocusMotionPolicy.shouldAnimate(mode:.generation,reduceMotion:true,windowVisible:true),"static gradient preserves hierarchy")
            try check("隐藏窗口停止动画",!FocusMotionPolicy.shouldAnimate(mode:.generation,reduceMotion:false,windowVisible:false),"Timeline paused after visibility notification")
            let hiddenDates = Array(FocusVisibilityTimelineSchedule(isVisible:false).entries(from:Date(),mode:.normal).prefix(3))
            let visibleDates = Array(FocusVisibilityTimelineSchedule(isVisible:true).entries(from:Date(),mode:.normal).prefix(3))
            try check("隐藏窗口停止定时刷新",hiddenDates.count == 1 && visibleDates.count == 3,"finite hidden schedule; one-second visible schedule")
            var original = ready;original.status = .completed;original.candidate = "/tmp/declared-old-candidate.mp4"
            var successor = ready;successor.id = UUID();successor.redoOf = original.id;original.supersededBy = successor.id
            let origin = ResultRouteOrigin.current(original)
            let direct = RedoRouteResolver.resolve(origin,jobs:[original,successor])
            try check("不同UUID真实重做导航",direct.target?.jobID == successor.id && direct.target?.status == successor.displayStatusLabel,"follows recorded lineage, not shot number")
            var third = successor;third.id = UUID();third.redoOf = successor.id;successor.supersededBy = third.id
            let multiple = RedoRouteResolver.resolve(origin,jobs:[original,successor,third])
            try check("多次重做默认最新并保留历史",multiple.target?.jobID == third.id && multiple.history.map(\.jobID) == [successor.id,third.id],"old targets remain navigable")
            try check("缺失目标禁用并解释",RedoRouteResolver.resolve(origin,jobs:[original]).target == nil,"original candidate remains intact")
            try check("同镜号无关系不能猜",RedoRouteResolver.resolve(.current(ready),jobs:[ready,third]).target == nil,"same shot does not prove successor")
            var cycle = third;cycle.supersededBy = original.id
            try check("循环或冲突关系拒绝导航",RedoRouteResolver.resolve(origin,jobs:[original,successor,cycle]).target == nil,"no arbitrary target")
            let r2 = revised(ready,number:2,previousHash:hashA),oldVersion = ResultRouteOrigin(jobID:ready.id,revision:1,frozenStateSHA256:hashA)
            let same = RedoRouteResolver.resolve(oldVersion,jobs:[r2])
            try check("同UUID新版按冻结关系导航",same.target?.jobID == ready.id && same.target?.revision == 2,"same selection still produces a new navigation intent")
            var r3 = revised(ready,number:3,previousHash:hashB)
            r3.resultRevisionLinks = r2.effectiveResultRevisionLinks
            try check("同UUID多次修订链可定位最新",RedoRouteResolver.resolve(oldVersion,jobs:[r3]).target?.revision == 3,"recorded historical edges survive revisions")
            try check("修订关系不全禁用",RedoRouteResolver.resolve(oldVersion,jobs:[revised(ready,number:3,previousHash:hashB)]).target == nil,"legacy missing links cannot be inferred")
            try check("旧结果指纹不符禁用",RedoRouteResolver.resolve(.init(jobID:ready.id,revision:1,frozenStateSHA256:hashB),jobs:[r2]).target == nil,"version number alone is insufficient")
            let decoded = try JSONDecoder().decode(ShotJob.self,from:JSONEncoder().encode(r3))
            try check("修订导航关系持久化",decoded.resultRevisionLinks == r3.resultRevisionLinks,"optional field remains backward compatible")
            try TaskVersionGroupingSelfTests.run(check: check)
            var otherPart = successor; otherPart.h3QueuePlan?.part = 2;otherPart.supersededBy = nil
            try check("不同分段不能归成同一任务",TaskVersionGrouping.project([original,otherPart]).count == 2,"even conflicting explicit links cannot merge different parts")
            let workspace = root.appendingPathComponent("workspace"),locations = ExternalLocations(originalProject:root.path,modelStatusRoot:root.path,ffmpeg:AppIdentity.ffmpeg)
            let value = try TaskStore(root:workspace,executable:executable,monitoring:false,locations:locations,h3Runtime:.mock(root:root,executable:executable));store = value
            value.add(original);value.add(successor);value.add(third);value.selectedID = original.id
            let stateEncoder = JSONEncoder();stateEncoder.outputFormatting = [.sortedKeys]
            let stateBefore = try stateEncoder.encode(value.state),diskBefore = try Data(contentsOf:workspace.appendingPathComponent("state.json"))
            let location = TaskNavigationLocation(selectedID:original.id,filter:"completed",inspectorTab:0,metrics:false,models:false)
            try check("结果跨页打开详情",value.navigateToRedo(origin,from:location) && value.selectedID == third.id && value.navigationIntent?.destination.filter == "all" && value.navigationIntent?.destination.inspectorTab == 0,"target is visible even when completed filter excluded it")
            try check("返回原结果与筛选",value.returnFromTaskNavigation() && value.selectedID == original.id && value.navigationIntent?.destination == location,"restores originating page")
            try check("可定位历史重做任务",value.navigateToRedo(origin,from:location,historyTarget:successor.id) && value.selectedID == successor.id,"uses selected recorded target")
            _ = value.returnFromTaskNavigation()
            try check("导航零GPU及写入副作用",value.launchCount == 0 && value.activeJob == nil && (try stateEncoder.encode(value.state)) == stateBefore && (try Data(contentsOf:workspace.appendingPathComponent("state.json"))) == diskBefore && !FileManager.default.fileExists(atPath:workspace.appendingPathComponent("h3-dispatch").path),"selection only: no dispatch, queue change, receipt or state write")
            let groups = TaskVersionGrouping.project(value.state.jobs)
            try check("真实导航映射到归组行",groups.count == 1 && groups[0].contains(value.selectedID) && groups[0].current.id == third.id,"existing navigation and version projection agree")
            value.state.jobs = [r2];value.selectedID = r2.id
            let token = value.navigationIntent?.id
            try check("同UUID导航刷新详情路由",value.navigateToRedo(oldVersion,from:.init(selectedID:r2.id,filter:"errors",inspectorTab:2)) && value.selectedID == r2.id && value.navigationIntent?.id != token,"fresh route token reopens details even when UUID is unchanged")
            value.state.jobs = [a,b];value.persist()
            _ = value.movePending(b.id,offset:-1)
            try check("真实重排与投影视图一致",value.fixtureQueueCandidates.first?.id == b.id && value.executionFocus().next?.job.id == b.id,"same scheduler candidates, not separate UI sorting")
            var historicalPending = a; historicalPending.supersededBy = b.id
            var currentPending = b; currentPending.redoOf = a.id
            var independent = a; independent.id = UUID()
            value.state.jobs = [historicalPending,currentPending,independent];value.persist()
            try check("重排只操作当前版本",!value.canMovePending(historicalPending.id,offset:1) && value.movePending(independent.id,offset:-1) && value.state.jobs[0].id == historicalPending.id,"hidden historical IDs cannot be reordered as current work")
            try check("拖动不能指向历史版本",!value.movePending(currentPending.id,before:historicalPending.id),"drag payload remains the exact current execution ID")
            value.state.jobs = [blocked,ready];value.persist()
            try check("H3调度候选与下一项一致",value.plannedPreparationCandidates.first?.id == ready.id && value.executionFocus().next?.job.id == ready.id && value.canPreparePlannedJob(ready.id),"skip blocked head in both code paths")
            var queuedH3 = blocked;queuedH3.status = .queued
            var cpu = a;cpu.fixtureDelay = 0.008
            value.state.jobs = [queuedH3,cpu];value.persist();value.startQueue();value.startQueue()
            try check("受阻H3不阻塞真实CPU队列",value.activeJob?.id == cpu.id && value.launchCount == 1,"only synthetic CPU subprocess; repeated start is idempotent")
            value.pauseQueue();value.cancel(cpu.id)
            try await StudioSelfTests.wait("CPU fixture cancellation",timeout:12) { value.activeJob == nil }
            try check("取消后投影停止动画",value.executionFocus().current == nil && !FocusMotionPolicy.shouldAnimate(mode:.idle,reduceMotion:false,windowVisible:true),"terminal state stops animation policy")
            value.shutdown();store = nil
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL exception: " + error.localizedDescription);store?.shutdown() }
        try? JSONEncoder().encode(checks).write(to:root.appendingPathComponent("test-report.json"),options:.atomic)
        return checks.contains { !$0.passed } ? 1 : 0
    }

    static func renderPreviews(root: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var active = planned(shot:35,priority:0);active.status = .running;active.stage = "采样生成";active.startedAt = Date(timeIntervalSince1970:1000)
            active.progress = .init(completed:2,total:4,unit:"步");active.executionActivity = .init(stage:active.stage,at:Date(timeIntervalSince1970:1090))
            let next = planned(shot:14,priority:1),focus = projection([active,next],idle:false)
            var original = active;original.status = .completed;var redo = next;redo.redoOf = original.id;original.supersededBy = redo.id
            let route = RedoRouteResolver.resolve(.current(original),jobs:[original,redo])
            var records: [[String:Any]] = []
            for (scheme,suffix) in [(ColorScheme.light,"light"),(.dark,"dark")] {
                for width in [796.0,1020.0] {
                    let view = ExecutionFocusCards(projection:focus,windowVisible:false).padding(20).frame(width:width)
                        .background(Palette(scheme:scheme).background).environment(\.colorScheme,scheme)
                    let renderer = ImageRenderer(content:view);renderer.scale = 2
                    guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw StudioError.invalid("SwiftUI 离屏渲染未返回图片") }
                    let name = "execution-focus-\(Int(width))-\(suffix).png";try data.write(to:root.appendingPathComponent(name),options:.atomic)
                    records.append(["file":name,"widthPoints":width,"pixels":[image.width,image.height],"fixture":true,"animationPaused":true])
                }
                let view = RedoTaskRouteCard(route:route,open:{ _ in }).padding(20).frame(width:302).background(Palette(scheme:scheme).surface).environment(\.colorScheme,scheme)
                let renderer = ImageRenderer(content:view);renderer.scale = 2
                guard let image = renderer.cgImage,let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw StudioError.invalid("重做导航离屏渲染未返回图片") }
                let name = "redo-navigation-\(suffix).png";try data.write(to:root.appendingPathComponent(name),options:.atomic)
                records.append(["file":name,"widthPoints":302,"pixels":[image.width,image.height],"fixture":true])
            }
            try JSONSerialization.data(withJSONObject:["scope":"Actual SwiftUI offscreen component renders; synthetic task data; not desktop screenshots or formal CUA","guiLaunched":false,"gpuGeneratorStarted":false,"records":records],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("preview-report.json"),options:.atomic)
            print("Saved 6 SwiftUI component previews; formal CUA pending.");return 0
        } catch { print(error.localizedDescription);return 1 }
    }
}
