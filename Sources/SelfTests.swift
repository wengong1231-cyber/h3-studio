import Foundation
import Darwin

@MainActor enum StudioSelfTests {
    struct Check: Codable { var name: String; var passed: Bool; var detail: String }
    static func wait(_ label: String, timeout: Double = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw StudioError.invalid("\(label) 超时") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func run(root: URL, executable: URL, includeNativeUI: Bool = true) async -> Int32 {
        var checks: [Check] = []
        func check(_ name: String, _ value: Bool, _ detail: String) throws {
            checks.append(Check(name: name, passed: value, detail: detail))
            FileHandle.standardOutput.write(Data("\(value ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let batch = root.appendingPathComponent("serial")
            var serial: TaskStore? = try TaskStore(root: batch, executable: executable, monitoring: false)
            let first = ShotJob.fixture(shot: 1, title: "正常进度", delay: 0.008)
            let second = ShotJob.fixture(shot: 2, title: "串行验证", delay: 0.008)
            serial!.add(first); serial!.add(second)
            serial!.startQueue(); serial!.startQueue(); serial!.startQueue()
            try check("重复开始不会重复启动", serial!.launchCount == 1 && serial!.state.jobs.filter { $0.status.isActive }.count == 1, "三次开始，仅一个生成子进程")
            var lockRejected = false
            do { _ = try TaskStore(root: batch, executable: executable, monitoring: false) } catch { lockRejected = true }
            try check("同工作区单实例锁", lockRejected, "第二个 store 被拒绝")
            try await wait("真实验证进度") { serial!.activeJob?.progress != nil }
            try check("进度来自实际事件", serial!.activeJob!.progress!.total == 48 && serial!.activeJob!.progress!.completed > 0, "使用实际写出的验证帧计数，无计时伪进度")
            serial!.pauseQueue()
            try await wait("当前镜头结束") { serial!.activeJob == nil }
            try check("暂停仅影响后续队列", serial!.completedCount == 1 && serial!.queuedCount == 1 && serial!.state.queuePaused, "当前镜头完成，后续未启动")
            guard let output = serial!.state.jobs.first?.candidate else { throw StudioError.invalid("缺少视频输出") }
            try check("候选视频实际存在", FileManager.default.fileExists(atPath: output) && output.hasPrefix(batch.path), output)
            serial!.startQueue()
            try await wait("第二镜头完成") { serial!.completedCount == 2 }
            try check("串行批处理", serial!.launchCount == 2, "两条任务各启动一次")
            serial = nil
            let restored = try TaskStore(root: batch, executable: executable, monitoring: false)
            try check("重启保留完成输出", restored.completedCount == 2 && restored.state.queuePaused && restored.state.jobs.first?.candidate == output, "状态与候选路径恢复，队列默认暂停")

            let failure = try TaskStore(root: root.appendingPathComponent("failure"), executable: executable, monitoring: false)
            let bad = ShotJob.fixture(shot: 3, title: "故障注入", failure: true, delay: 0.004)
            failure.add(bad); failure.add(.fixture(shot: 4, title: "失败后不自动运行", delay: 0.004)); failure.startQueue()
            try await wait("注入失败") { failure.failedCount == 1 }
            try check("失败停止队列且保留日志", failure.state.queuePaused && failure.queuedCount == 1 && failure.state.jobs[0].error?.contains("第 13 帧") == true && !failure.state.jobs[0].logTail.isEmpty, "失败没有触发自动重试")
            failure.retry(bad.id); failure.retry(bad.id)
            try check("重复重试不会新增任务", failure.state.jobs.count == 2 && failure.state.jobs[0].attempts.count == 1, "重试只重排已有任务")
            failure.startQueue(); failure.pauseQueue()
            try await wait("重试成功") { failure.state.jobs[0].status == .completed }
            try check("重试输出隔离", failure.state.jobs[0].attempts.count == 2 && failure.state.jobs[0].candidate?.contains("attempt-2") == true, "首次失败目录保留，重试使用新目录")

            let cancel = try TaskStore(root: root.appendingPathComponent("cancel"), executable: executable, monitoring: false)
            let cancellable = ShotJob.fixture(shot: 5, title: "取消验证", delay: 0.08)
            cancel.add(cancellable); cancel.startQueue()
            try await wait("取消前进度") { cancel.activeJob?.progress != nil }
            cancel.cancel(cancellable.id); cancel.cancel(cancellable.id)
            try await wait("取消结束") { cancel.activeJob == nil }
            let firstDirectory = cancel.state.jobs[0].attempts[0].directory
            try check("取消与重复取消", cancel.state.jobs[0].status == .cancelled && cancel.state.queuePaused && FileManager.default.fileExists(atPath: firstDirectory + "/frames/frame-0000.ppm"), "已写出的验证帧保留")

            let orderRoot = root.appendingPathComponent("queue-order")
            var order: TaskStore? = try TaskStore(root: orderRoot, executable: executable, monitoring: false)
            var history = ShotJob.fixture(shot: 80, title: "已完成记录固定")
            history.status = .completed; history.candidate = output
            let h3A = ShotJob(shot: 81, segment: "h3-a", title: "等待 H3 A", prompt: "", requestedDuration: 2, engine: .h3, status: .blocked)
            let h3B = ShotJob(shot: 82, segment: "h3-b", title: "等待 H3 B", prompt: "", requestedDuration: 2, engine: .h3, status: .blocked)
            let pendingC = ShotJob.fixture(shot: 83, title: "待执行 C")
            order!.add(history); order!.add(h3A); order!.add(h3B); order!.add(pendingC)
            try check("等待数量包含模型阻塞任务", order!.pendingCount == 3 && order!.queuedCount == 1, "等待模型的 H3 属于待执行，但不会启动 GPU")
            let movedUp = order!.movePending(h3B.id, offset: -1)
            try check("待执行上移不移动历史或改变选中", movedUp && order!.state.jobs.map(\.id) == [history.id, h3B.id, h3A.id, pendingC.id] && order!.selectedID == pendingC.id, "按稳定 UUID 操作，完成记录保持原位")
            let dropped = order!.movePending(pendingC.id, before: h3B.id)
            let repeatedDrop = order!.movePending(pendingC.id, before: h3B.id)
            try check("待执行拖动重排及重复提交", dropped && !repeatedDrop && order!.state.jobs.map(\.id) == [history.id, pendingC.id, h3B.id, h3A.id], "一次 drop 原子保存顺序，重复 drop 不改动")
            order!.selectedID = h3B.id; order!.cancel(h3A.id)
            let cancellationDate = order!.state.jobs.last!.updatedAt
            order!.cancel(h3A.id)
            try check("等待 H3 可取消且不会取消选中另一条", order!.state.jobs.last!.status == .cancelled && order!.state.jobs.last!.updatedAt == cancellationDate && order!.selected?.id == h3B.id && order!.selected?.status == .blocked && order!.launchCount == 0, "取消重复点击幂等，等待模型也可取消")
            let savedOrder = order!.state.jobs.map(\.id)
            order = nil
            let reopenedOrder = try TaskStore(root: orderRoot, executable: executable, monitoring: false)
            try check("重开保持队列顺序与取消状态", reopenedOrder.state.jobs.map(\.id) == savedOrder && reopenedOrder.state.jobs.last?.status == .cancelled, "真实 state.json 恢复，并保持队列暂停")
            reopenedOrder.cancel(history.id)
            try check("完成输出不受排序取消影响", !reopenedOrder.movePending(history.id, offset: 1) && reopenedOrder.state.jobs[0].candidate == output && FileManager.default.fileExists(atPath: output), "完成记录不可排序或取消，候选文件保留")

            let liveOrder = try TaskStore(root: root.appendingPathComponent("live-order"), executable: executable, monitoring: false)
            let live = ShotJob.fixture(shot: 84, title: "运行记录固定", delay: 0.15)
            let liveA = ShotJob.fixture(shot: 85, title: "后续 A")
            let liveB = ShotJob.fixture(shot: 86, title: "后续 B")
            liveOrder.add(live); liveOrder.add(liveA); liveOrder.add(liveB); liveOrder.startQueue()
            try await wait("运行排序前进度") { liveOrder.activeJob?.progress != nil }
            let livePID = liveOrder.activeJob?.workerPID
            let cannotMoveLive = !liveOrder.movePending(live.id, offset: 1) && !liveOrder.movePending(live.id, before: liveA.id)
            let futureMoved = liveOrder.movePending(liveB.id, offset: -1)
            try check("运行中仅重排后续任务不重新启动", cannotMoveLive && futureMoved && liveOrder.state.jobs[0].id == live.id && liveOrder.activeJob?.workerPID == livePID && liveOrder.launchCount == 1, "当前运行 UUID、PID 和启动次数保持不变")
            liveOrder.selectedID = liveA.id; liveOrder.cancel(liveB.id)
            try check("取消后续任务不停止当前运行", liveOrder.activeJob?.workerPID == livePID && liveOrder.state.jobs[1].status == .cancelled && liveOrder.selected?.status == .queued, "每行操作绑定 UUID，不依赖当前详情选择")
            let sentinel = Process(); sentinel.executableURL = URL(fileURLWithPath: "/bin/cat")
            sentinel.standardInput = Pipe(); sentinel.standardOutput = FileHandle.nullDevice; sentinel.standardError = FileHandle.nullDevice
            try sentinel.run()
            defer { if sentinel.isRunning { sentinel.terminate() } }
            liveOrder.cancel(live.id); liveOrder.cancel(live.id)
            liveOrder.consume("{\"type\":\"stage\",\"stage\":\"迟到的阶段消息\"}", stderr: false, jobID: live.id, attemptNumber: 1)
            try check("取消中状态不被迟到事件覆盖", liveOrder.activeJob?.status == .cancelling && liveOrder.activeJob?.stage.contains("正在取消") == true, "异步消息仍记日志，界面保留取消状态")
            try await wait("排序后运行取消") { liveOrder.activeJob == nil }
            let cancelledFrames = liveOrder.state.jobs[0].attempts[0].directory + "/frames/frame-0000.ppm"
            try check("取消只停止目标进程并保留部分输出", liveOrder.state.jobs[0].status == .cancelled && sentinel.isRunning && FileManager.default.fileExists(atPath: cancelledFrames) && liveOrder.launchCount == 1, "独立 sentinel 不受影响，后续未启动，已写帧保留")

            let manifestURL = root.appendingPathComponent("shots.json")
            let json: [String: Any] = ["shots": [["number": 25, "label": "洛神", "source_image": "reference.png", "output_clip": "/must/not/overwrite.mp4", "target_duration_seconds": 5.167, "prompt": "原始动作提示"]]]
            try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
            let imported = try TaskStore(root: root.appendingPathComponent("import"), executable: executable, monitoring: false)
            let count = try imported.importManifest(manifestURL)
            let duplicate = try imported.importManifest(manifestURL)
            imported.startQueue()
            try check("安全导入与去重", count == 1 && duplicate == 0 && imported.state.jobs[0].status == .blocked && imported.launchCount == 0 && imported.state.jobs[0].candidate == nil, "H3 未接入时不启动，忽略生产 output_clip")
            let jobsJSON: [String: Any] = ["profile": ["width": 768, "height": 448, "frames": 124, "steps": 4, "fps": 24], "jobs": [["id": "s38-p01", "shot": 38, "first": "ref.png", "prompt": "a", "clip": "/production.mp4"]]]
            let parsed = try ManifestImporter.parse(JSONSerialization.data(withJSONObject: jobsJSON), url: root.appendingPathComponent("continuation.json"))
            try check("兼容 H3 continuation manifest", parsed.first?.segment == "s38-p01" && parsed.first?.parameters.frames == 124 && parsed.first?.parameters.verified == false, "参数标注为待核准，原输出路径不成为候选")

            let phase = VpipePhaseProgressParser.parse("[PROGRESS] 10% of 'denoise' completed at 08:37:27 (20/200)")
            let decode = VpipePhaseProgressParser.parse("[PROGRESS] 100% of 'vae decode' completed at 08:55:38 (56/56)")
            try check("核准的 VPIPE 阶段进度解析", phase?.completed == 20 && phase?.total == 200 && decode?.stage == "vae decode" && decode?.total == 56, "只解析阶段 done/total，不当作全片进度")
            try check("拒绝无效 VPIPE 百分比", VpipePhaseProgressParser.parse("[PROGRESS] 100% of 'denoise' completed at 00:00 (20/0)") == nil, "零分母不变成完成状态")
            let downloadJSON: [String: Any] = ["status": "running", "updated_at": "2026-01-01T00:00:00Z", "downloaded_bytes": 250,
                "expected_bytes": 1000, "verified_files": 0, "total_files": 1, "quantization_still_required": true,
                "generation_started": false, "files": [["relative_path": "model.safetensors", "size": 1000, "state": "downloading", "downloaded_bytes": 250]]]
            let downloadData = try JSONSerialization.data(withJSONObject: downloadJSON)
            let download = try DownloadSnapshot.parse(downloadData, manifestTotal: 1000)
            try check("下载进度来自真实字节字段", download.fraction == 0.25 && download.stale() && !download.generation_started, "250/1000 = 25%；旧快照标为过期，不声称仍在运行或已生成")
            var mismatchedManifest = false
            do { _ = try DownloadSnapshot.parse(downloadData, manifestTotal: 999) } catch { mismatchedManifest = true }
            try check("下载状态绑定核准清单", mismatchedManifest, "不同总字节的状态被拒绝")

            let crashRoot = root.appendingPathComponent("crash")
            let harness = Process(); harness.executableURL = executable; harness.arguments = ["--crash-harness", crashRoot.path]
            harness.standardOutput = FileHandle.nullDevice; harness.standardError = FileHandle.nullDevice
            try harness.run()
            try await wait("崩溃 harness 启动") { FileManager.default.fileExists(atPath: crashRoot.appendingPathComponent("harness-ready").path) }
            try await Task.sleep(nanoseconds: 300_000_000)
            kill(harness.processIdentifier, SIGKILL); harness.waitUntilExit()
            let recovered = try TaskStore(root: crashRoot, executable: executable, monitoring: false)
            try check("实际进程崩溃恢复", recovered.state.jobs.first?.status == .interrupted && recovered.state.queuePaused && recovered.launchCount == 0 && recovered.state.jobs.first?.attempts.count == 1, "SIGKILL 应用后恢复记录，不自动续跑")
            try await wait("孤儿验证进程安全退出", timeout: 4) { recovered.recoveredPIDs.isEmpty }
            try check("孤儿进程看门狗", recovered.recoveredPIDs.isEmpty, "旧 worker 因父进程或 owner lease 消失退出，没有杀无关进程")
            recovered.retry(recovered.state.jobs[0].id); recovered.state.jobs[0].fixtureDelay = 0.004; recovered.startQueue()
            try await wait("恢复重试完成") { recovered.completedCount == 1 }
            try check("恢复后可手动重试", recovered.state.jobs[0].attempts.count == 2, "新尝试目录独立")

            let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
            let negativeDisplay = NSRect(x: -1280, y: -200, width: 1280, height: 1000)
            var tracking = OrbDragSession(pointerAtPress: NSPoint(x: 600, y: 400), originAtPress: NSPoint(x: 379, y: 353))
            var stable = true
            for delta in 5...200 {
                let offset = CGFloat(delta)
                let pointer = NSPoint(x: 600 + offset, y: 400 + offset)
                stable = stable && tracking.update(pointer: pointer) == NSPoint(x: 379 + offset, y: 353 + offset)
            }
            try check("悬浮球屏幕坐标连续跟手", stable, "196 个屏幕点事件逐点匹配；窗口移动不反馈到坐标基准，不按 Retina 像素倍增")
            var click = OrbDragSession(pointerAtPress: NSPoint(x: 100, y: 100), originAtPress: NSPoint(x: 10, y: 10))
            let jitter = click.update(pointer: NSPoint(x: 104, y: 102))
            var isClick = false
            if case .click = click.release(pointer: NSPoint(x: 102, y: 101), visibleFrames: [primary]) { isClick = true }
            try check("悬浮球点击容忍微小抖动", jitter == nil && isClick, "小于 5 个逻辑点时窗口不动，松手才展开")
            var returned = OrbDragSession(pointerAtPress: NSPoint(x: 600, y: 400), originAtPress: NSPoint(x: 379, y: 353))
            _ = returned.update(pointer: NSPoint(x: 620, y: 400))
            var remainsDrag = false
            if case .moved(let point) = returned.release(pointer: NSPoint(x: 600, y: 400), visibleFrames: [primary]) { remainsDrag = point == NSPoint(x: 379, y: 353) }
            try check("悬浮球拖回起点不误触展开", remainsDrag, "一旦越过拖动阈值，本次按下不会再变为点击")
            var lastEvent = OrbDragSession(pointerAtPress: NSPoint(x: 600, y: 400), originAtPress: NSPoint(x: 379, y: 353))
            var finalPoint = NSPoint.zero
            if case .moved(let point) = lastEvent.release(pointer: NSPoint(x: 610, y: 405), visibleFrames: [primary]) { finalPoint = point }
            try check("悬浮球松手包含最后位移", finalPoint == NSPoint(x: 389, y: 358), "即使最后拖动事件被合并，release 使用当前屏幕指针")
            let seam = NSPoint(x: 1218, y: 450)
            try check("悬浮球跨屏接缝不吸边跳跃", OrbGeometry.constrained(seam, visibleFrames: [primary, secondary]) == seam, "按相邻显示器可见区域的并集判断，允许跨屏接缝")
            let leftPoint = NSPoint(x: -800, y: -100)
            try check("悬浮球支持负坐标显示器", OrbGeometry.constrained(leftPoint, visibleFrames: [primary, negativeDisplay]) == leftPoint, "AppKit 全屏坐标保留负值及上下屏布局")
            let bottomLeft = OrbGeometry.constrained(NSPoint(x: -1000, y: -1000), visibleFrames: [primary])
            let topRight = OrbGeometry.constrained(NSPoint(x: 2000, y: 2000), visibleFrames: [primary])
            try check("悬浮球四边约束仅针对可见球体", bottomLeft == NSPoint(x: -178, y: -4) && topRight == NSPoint(x: 1176, y: 810), "8 点外缘留白；不把左侧透明提示区当作球体")
            let disconnected = NSRect(x: 1600, y: 0, width: 1000, height: 900)
            let gap = NSRect(x: 1410, y: 300, width: 220, height: 70)
            try check("悬浮球不把显示器空隙当作桌面", !OrbGeometry.covered(gap, by: [primary, disconnected]) && OrbGeometry.covered(NSRect(x: 1410, y: 300, width: 70, height: 70), by: [primary, secondary]), "联合覆盖检查拒绝空隙，接受真实相邻接缝")
            let savedOffscreen = NSPoint(x: 2300, y: 450)
            let restoredPoint = OrbGeometry.constrained(savedOffscreen, visibleFrames: [primary])
            try check("悬浮球移除显示器后安全恢复", restoredPoint == NSPoint(x: 1176, y: 450), "保存位置所在屏幕移除后，恢复到最近可见边界")
            let positionRoot = root.appendingPathComponent("orb-position")
            var positionStore: TaskStore? = try TaskStore(root: positionRoot, executable: executable, monitoring: false)
            positionStore!.setOrbOrigin(x: finalPoint.x, y: finalPoint.y)
            positionStore = nil
            let reopenedPosition = try TaskStore(root: positionRoot, executable: executable, monitoring: false)
            try check("悬浮球松手位置持久恢复", reopenedPosition.state.orbX == finalPoint.x && reopenedPosition.state.orbY == finalPoint.y, "单次提交位置经真实 state.json 写入后重新打开恢复；不改生产队列")

            try await StudioLifecycleTests.run(root: root.appendingPathComponent("lifecycle"), executable: executable, includeNativeUI: includeNativeUI, check: check)

            let installFixtureRoot = root.appendingPathComponent("migration-real-cpu", isDirectory: true)
            let oldRoot = installFixtureRoot.appendingPathComponent("project/Data", isDirectory: true)
            var oldStore: TaskStore? = try TaskStore(root: oldRoot, executable: executable, monitoring: false)
            oldStore!.add(.fixture(shot: 110, title: "迁移前真实 CPU 候选", delay: 0.008)); oldStore!.startQueue()
            try await wait("迁移前 CPU 候选") { oldStore!.completedCount == 1 }
            let oldVideo = URL(fileURLWithPath: oldStore!.state.jobs[0].candidate!)
            let oldVideoHash = try WorkspaceDigest.sha256(oldVideo)
            let oldStateHash = try WorkspaceDigest.sha256(oldRoot.appendingPathComponent("state.json"))
            oldStore = nil
            let migrator = WorkspaceMigrator(supportRoot: installFixtureRoot.appendingPathComponent("Application Support/\(AppIdentity.bundleID)", isDirectory: true))
            _ = try migrator.migrate(legacy: oldRoot)
            var settings = try migrator.loadSettings()!
            settings.externalLocations.originalProject = installFixtureRoot.appendingPathComponent("external-project").path
            settings.externalLocations.modelStatusRoot = installFixtureRoot.appendingPathComponent("external-download-status").path
            try JSONEncoder().encode(settings).write(to: migrator.settingsURL, options: .atomic)
            let context = try migrator.resolve(legacyHint: oldRoot)
            let installedStore = try TaskStore(root: context.root, executable: executable, monitoring: false, locations: context.settings.externalLocations)
            let preservedVideo = URL(fileURLWithPath: installedStore.state.jobs[0].candidate!)
            try check("迁移后真实 CPU 视频完整", try WorkspaceDigest.sha256(preservedVideo) == oldVideoHash && preservedVideo.path.hasPrefix(context.root.path + "/") && installedStore.state.queuePaused, "已有 48 帧合成视频逐字节相同，新工作区默认暂停")
            try check("安装版持久路径注入到引擎和状态读取", installedStore.readiness.root.path == settings.externalLocations.modelStatusRoot && installedStore.locations == settings.externalLocations, "外部状态路径从 settings 读取，未移动或读取夹具外模型")
            installedStore.add(.fixture(shot: 111, title: "迁移后真实 CPU 候选", delay: 0.008)); installedStore.startQueue(); installedStore.startQueue()
            try await wait("新工作区 CPU 候选") { installedStore.completedCount == 2 }
            let newJob = installedStore.state.jobs[1]
            let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: newJob.attempts[0].directory + "/request.json")))
            try check("迁移后生成只写标准工作区", newJob.candidate!.hasPrefix(context.root.path + "/") && request.workspace == context.root.path && request.outputDirectory.hasPrefix(context.root.path + "/") && request.ffmpeg == settings.externalLocations.ffmpeg && installedStore.launchCount == 1, "新生成参数与候选落在新路径，重复开始仍串行一次")
            try check("新生成保留旧工作区及旧候选", try WorkspaceDigest.sha256(oldVideo) == oldVideoHash && WorkspaceDigest.sha256(oldRoot.appendingPathComponent("state.json")) == oldStateHash && WorkspaceDigest.sha256(preservedVideo) == oldVideoHash, "新队列执行不回写旧 Data，也不覆盖迁移前已完成视频")
            withExtendedLifetime(context) {}

            let metric = TelemetryMonitor(root: root)
            metric.ownedPIDs = { [getpid()] }
            var totalSampling = 0.0, maximum = 0.0
            let begin = ProcessInfo.processInfo.systemUptime
            for _ in 0..<40 { let sample = metric.sampleNow(); totalSampling += sample.samplingMilliseconds; maximum = max(maximum, sample.samplingMilliseconds) }
            let benchTime = ProcessInfo.processInfo.systemUptime - begin
            func cpuSeconds() -> Double {
                var usage = rusage(); getrusage(Int32(RUSAGE_SELF), &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            }
            let enabledCPUStart = cpuSeconds()
            let enabledCount = metric.samples.count
            metric.configure(enabled: true, interval: 2)
            try await Task.sleep(nanoseconds: 2_200_000_000)
            let enabledCPU = cpuSeconds() - enabledCPUStart
            let enabledAdded = metric.samples.count - enabledCount
            metric.configure(enabled: false, interval: 2)
            let offCount = metric.samples.count
            let disabledCPUStart = cpuSeconds()
            try await Task.sleep(nanoseconds: 2_200_000_000)
            let disabledCPU = cpuSeconds() - disabledCPUStart
            try check("监控关闭不继续采样", metric.samples.count == offCount && !metric.enabled, "关闭后计数保持不变")
            let telemetryReport: [String: Any] = ["reads": 40, "average_sampling_ms": totalSampling / 40, "maximum_sampling_ms": maximum,
                "wall_seconds": benchTime, "default_interval_seconds": 5, "estimated_wall_fraction_at_5_seconds": (totalSampling / 40) / 5000,
                "off_samples_added": metric.samples.count - offCount, "app_footprint_available": metric.latest?.appFootprintMB != nil,
                "enabled_window_samples_added": enabledAdded, "enabled_window_cpu_seconds": enabledCPU,
                "disabled_window_cpu_seconds": disabledCPU, "comparison_window_seconds": 2.2,
                "system_cpu_available": metric.latest?.cpuPercent != nil, "system_memory_available": metric.latest?.systemUsedMB != nil,
                "disk_free_available": metric.latest?.diskFreeGB != nil, "gpu_available": metric.latest?.gpu?.utilizationPercent != nil,
                "gpu_scope": "whole device driver reported", "gpu_minimum_interval_seconds": 5,
                "method": "40 low-permission reads plus 2.2-second enabled/disabled windows using self getrusage; headless harness CPU, excludes UI rendering"]
            try JSONSerialization.data(withJSONObject: telemetryReport, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("telemetry-benchmark.json"))
            try check("监控采样开销实测", totalSampling / 40 < 20, String(format: "平均 %.3f ms，最大 %.3f ms，默认每 5 秒；缺值保留", totalSampling / 40, maximum))
            let report: [String: Any] = ["passed": true, "checks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(checks)), "test_root": root.path,
                "real_h3_launched": false, "native_ui_checks_executed": includeNativeUI, "native_ui_checks_skipped": includeNativeUI ? 0 : 7,
                "date": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("test-report.json"))
            return 0
        } catch {
            checks.append(Check(name: "unexpected error", passed: false, detail: error.localizedDescription))
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("test-report.json")) }
            return 1
        }
    }
}
