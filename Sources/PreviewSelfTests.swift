import Foundation
import Combine
import CoreGraphics
import AVFoundation

@MainActor enum PreviewSelfTests {
    static func load(_ service: PreviewImageService,_ key: PreviewImageKey) async -> PreviewReadResult {
        await withCheckedContinuation { continuation in service.request(key,scope:.test) { continuation.resume(returning:$0) } }
    }
    static func bitmap(_ result: PreviewReadResult) throws -> PreviewBitmap {
        switch result.result { case .success(let value): return value;case .failure(let error): throw error }
    }
    static func pixelHash(_ value: PreviewBitmap) -> String { H3ABConfigurationReader.digest(value.image.dataProvider!.data! as Data) }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            // Exercise a real, isolated CPU fixture. No production candidate is
            // rewritten and this test never starts an H3 model.
            let movie = root.appendingPathComponent("playback-fixture.mp4")
            try await H3FirstSelfTests.movie(movie)
            let movieHash = try WorkspaceDigest.sha256(movie)
            let playback = try CandidatePlaybackSession(path:movie.path)
            defer { playback.stop() }
            playback.start()
            try await StudioSelfTests.wait("candidate autoplay",timeout:10) { playback.player.currentTime().seconds > 0.15 }
            try check("大窗打开后真实自动播放",playback.started && playback.player.currentItem?.status == .readyToPlay && playback.player.rate > 0,"CPU 视频播放时钟已前进，无需再次点播放")
            playback.togglePlayback()
            try await StudioSelfTests.wait("candidate controls paused",timeout:3) { !playback.playing }
            let item = playback.player.currentItem
            for _ in 0..<100 { playback.start() }
            try check("重复呈现不重建播放器或打断暂停",playback.player.currentItem === item && playback.player.rate == 0,"重复启动请求不能复位时间或自动恢复用户暂停")
            playback.seek(to:1.2)
            try await StudioSelfTests.wait("candidate seek",timeout:5) { abs(playback.player.currentTime().seconds-1.2) < 0.1 }
            try check("常驻进度条定位真实视频时间",abs(playback.position-1.2) < 0.1 && playback.duration > 1.9,"使用与界面相同的seek入口，暂停中拖动后不自动播放")
            playback.seek(to:playback.duration)
            try await StudioSelfTests.wait("candidate end seek",timeout:5) { playback.player.currentTime().seconds > 1.9 }
            playback.togglePlayback()
            try await StudioSelfTests.wait("candidate replay",timeout:5) { playback.playing && playback.position < 1 }
            try check("播完可从头重播",playback.player.rate > 0 && playback.player.currentTime().seconds < 1,"播放按钮从片尾跳回开头，不停在结束帧")
            playback.stop()
            let stoppedAt = playback.player.currentTime().seconds
            try await Task.sleep(nanoseconds:150_000_000)
            playback.start()
            try check("关闭播放窗立即停止且不能意外复活",playback.closed && playback.player.rate == 0 && abs(playback.player.currentTime().seconds-stoppedAt) < 0.1,"关闭后迟到回调和重复启动不能继续播放")
            let reopened = try CandidatePlaybackSession(path:movie.path)
            defer { reopened.stop() }
            try check("重新打开从开头建立独立播放",reopened.player.currentItem !== item && reopened.player.currentTime().seconds == 0,"不继承上个已关闭窗口的进度或暂停状态")
            let badMovie = root.appendingPathComponent("unplayable.mp4")
            try Data("invalid media fixture".utf8).write(to:badMovie)
            let failedPlayback = try CandidatePlaybackSession(path:badMovie.path)
            defer { failedPlayback.stop() }
            failedPlayback.start()
            try await StudioSelfTests.wait("candidate playback failure",timeout:10) { failedPlayback.failure != nil }
            try check("坏视频显示播放失败并停止",failedPlayback.failure != nil && failedPlayback.player.rate == 0,"读取失败不会显示已通过或改动任务验收")
            var rejectedMissing = false
            do { _ = try CandidatePlaybackSession(path:root.appendingPathComponent("missing.mp4").path) }
            catch { rejectedMissing = true }
            try check("缺失视频在打开前明确报错",rejectedMissing && (try WorkspaceDigest.sha256(movie)) == movieHash,"测试和播放都没有改写候选文件")
            let compact = CandidatePlaybackController.contentSize(visibleFrame:CGRect(x:0,y:0,width:1024,height:640))
            let roomy = CandidatePlaybackController.contentSize(visibleFrame:CGRect(x:0,y:0,width:1920,height:1080))
            try check("大播放窗适应可见屏幕",compact.width < 1024 && compact.height < 640 && roomy.width == 1100 && roomy.height == 720,"小屏保留边距，普通屏以1100×720内容区打开并可继续缩放")
            let a = root.appendingPathComponent("A-private-name.png"),b = root.appendingPathComponent("B-private-name.png")
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:8,width:1024,height:512),to:a,width:1024,height:512)
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:35,width:1024,height:512),to:b,width:1024,height:512)
            let ka = PreviewImageKey(path:a.path,maxPixel:128),kb = PreviewImageKey(path:b.path,maxPixel:128)
            let service = PreviewImageService();service.configureDiagnostics(root:root)
            let first = try bitmap(await load(service,ka)),firstHash = pixelHash(first)
            try check("后台缩略图有真实尺寸上限",first.image.width == 128 && first.image.height == 64 && first.cost <= 128*64*4,"ImageIO 实际降采样1024×512，原图没有改写")
            let hit = await load(service,ka)
            try check("稳定文件复用解码缓存",hit.cacheHit && service.statistics().decodes == 1 && pixelHash(try bitmap(hit)) == firstHash,"后台校验文件身份，重复请求复用已解码图片")
            let replacement = root.appendingPathComponent("replacement.png")
            try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:51,width:1024,height:512),to:replacement,width:1024,height:512)
            try Data(contentsOf:replacement).write(to:a,options:.atomic)
            let changed = await load(service,ka),changedHash = pixelHash(try bitmap(changed))
            try check("同路径图片变化使缓存失效",!changed.cacheHit && service.statistics().decodes == 2 && changedHash != firstHash,"校验设备/inode/字节数/纳秒修改时间，读取新像素")
            let revised = await load(service,.init(path:a.path,revision:"new binding",maxPixel:128))
            try check("配置指纹变化独立失效",!revised.cacheHit && service.statistics().decodes == 3,"同路径的新绑定不继承旧预览请求身份")
            let second = try bitmap(await load(service,kb))
            try check("不同路径不会串图",pixelHash(second) != changedHash,"A/B 使用独立请求键与真实像素")
            let small = PreviewImageService(cacheByteLimit:40_000,cacheEntryLimit:1)
            _ = await load(small,ka);_ = await load(small,kb);let evicted = await load(small,ka)
            try check("缓存字节与条目均有界",small.statistics().cacheEntries == 1 && small.statistics().cacheBytes <= 40_000 && !evicted.cacheHit,"真实LRU淘汰后重新解码，不保留无界大图缓存")
            let missing = await load(service,.init(path:root.appendingPathComponent("missing.png").path))
            try check("读取失败有明确错误且不造占位结果",{ if case .failure(.missing) = missing.result { return true };return false }(),"不存在文件返回missing，没有假预览")
            let corrupt = root.appendingPathComponent("corrupt.png");try Data("not an image".utf8).write(to:corrupt)
            let invalid = await load(service,.init(path:corrupt.path))
            try check("坏图片不进入成功缓存",{ if case .failure = invalid.result { return true };return false }(),"ImageIO 拒绝坏格式，错误不含私有路径")
            let forbidden = await load(service,.init(path:root.appendingPathComponent("sessions/not-opened.png").path))
            try check("受禁路径在打开前拒绝",{ if case .failure(.invalidPath) = forbidden.result { return true };return false }(),"不访问受禁目录，也不请求系统权限")

            let slow = PreviewImageService(timeout:1,beforeRead:{ Thread.sleep(forTimeInterval:0.15) });slow.configureDiagnostics(root:root)
            let model = PreviewImageModel(),began = ProcessInfo.processInfo.systemUptime
            model.begin(ka,scope:.test,service:slow)
            try await Task.sleep(nanoseconds:30_000_000)
            try check("慢读取不占用主 actor",ProcessInfo.processInfo.systemUptime-began < 0.12 && slow.statistics().activeReads == 1 && model.bitmap == nil,"30ms 主 actor 回调执行，实际后台读取仍未结束")
            model.begin(kb,scope:.test,service:slow)
            try await StudioSelfTests.wait("current B preview",timeout:3) { model.bitmap != nil }
            try check("切换路径拒绝迟到旧结果",model.key == kb && pixelHash(model.bitmap!) == pixelHash(second) && model.discardedCount > 0,"A 的取消/迟到回调不能回写已选择的 B")
            for i in 0..<30 { model.begin(i.isMultiple(of:2) ? ka : kb,scope:.test,service:slow) }
            try await StudioSelfTests.wait("rapid latest preview",timeout:3) { model.bitmap != nil }
            try check("快速重选最终只展示最新图片",model.key == kb && pixelHash(model.bitmap!) == pixelHash(second) && slow.statistics().peakActiveReads <= 2,"连续切换有取消和代际检查，最多两路实际后台读取")
            model.begin(.init(path:a.path,revision:"cancel-on-close",maxPixel:128),scope:.test,service:slow);model.cancel()
            try await Task.sleep(nanoseconds:200_000_000)
            try check("关闭预览后不回写图片",model.key == nil && model.bitmap == nil && model.failure == nil,"关闭使代际失效；取消只作用于预览订阅")

            let bounded = PreviewImageService(flightLimit:4,timeout:0.05,beforeRead:{ Thread.sleep(forTimeInterval:0.25) })
            var results: [PreviewReadResult] = []
            for i in 0..<40 { bounded.request(.init(path:a.path,revision:String(i),maxPixel:128),scope:.test) { results.append($0) } }
            try await StudioSelfTests.wait("bounded responses",timeout:2) { results.count == 40 }
            let failures = results.compactMap { value -> PreviewImageFailure? in if case .failure(let error) = value.result { return error };return nil }
            try check("超时不无限新增读取或排队",bounded.statistics().peakActiveReads <= 2 && bounded.statistics().flights <= 4 && failures.contains(.timedOut) && failures.contains(.busy),"两路慢读占槽到实际返回；其余有界排队或明确繁忙")
            try await StudioSelfTests.wait("preview readers drained",timeout:2) { bounded.statistics().flights == 0 && slow.statistics().flights == 0 }
            let cancelledQueue = PreviewImageService(beforeRead:{ Thread.sleep(forTimeInterval:0.15) })
            var drained = 0
            _ = cancelledQueue.request(.init(path:a.path,revision:"hold1"),scope:.test) { _ in drained += 1 }
            _ = cancelledQueue.request(.init(path:b.path,revision:"hold2"),scope:.test) { _ in drained += 1 }
            let queuedKey = PreviewImageKey(path:a.path,revision:"queued-return",maxPixel:128)
            let token = cancelledQueue.request(queuedKey,scope:.test) { _ in drained += 1 };cancelledQueue.cancel(token)
            let reselected = await load(cancelledQueue,queuedKey)
            try check("取消的排队图片可正常重选",(try? bitmap(reselected)) != nil,"不会把新订阅挂到已取消的排队操作上")
            try await StudioSelfTests.wait("cancel queue drain",timeout:2) { drained == 3 && cancelledQueue.statistics().flights == 0 }

            let store = try TaskStore(root:root.appendingPathComponent("heartbeat"),executable:executable,monitoring:false)
            var notifications = 0;let subscription = store.objectWillChange.sink { notifications += 1 }
            for _ in 0..<100 { store.heartbeatTick(isAlive:{ _ in false }) }
            try check("空恢复列表的重复心跳不发布",notifications == 0,"一百次相同状态不触发多余 ObservableObject 更新")
            store.recoveredPIDs = [12345];notifications = 0
            for _ in 0..<100 { store.heartbeatTick(isAlive:{ _ in true }) }
            try check("未变化的存活列表不发布",notifications == 0 && store.recoveredPIDs == [12345],"注入只针对测试PID的存活判断，没有全局进程扫描")
            store.heartbeatTick(isAlive:{ _ in false });let published = notifications
            store.heartbeatTick(isAlive:{ _ in false })
            try check("真实恢复变化恰好发布一次",published == 1 && notifications == 1 && store.recoveredPIDs.isEmpty,"真实消失仍能通知队列和界面")
            withExtendedLifetime(subscription) {};store.shutdown()

            let standard = WorkspaceMigrator.defaultSupportRoot.appendingPathComponent("Workspace/state.json")
            if FileManager.default.fileExists(atPath:standard.path) {
                let before = try Data(contentsOf:standard),state = try JSONDecoder().decode(WorkspaceState.self,from:before)
                let copyRoot = root.appendingPathComponent("history-records");try FileManager.default.createDirectory(at:copyRoot,withIntermediateDirectories:true);try before.write(to:copyRoot.appendingPathComponent("state.json"))
                let copy = try TaskStore(root:copyRoot,executable:executable,monitoring:false)
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
                for _ in 0..<100 { copy.heartbeatTick(isAlive:{ _ in false }) }
                try check("现有真实历史在隔离副本保持不变",state.jobs.count == copy.state.jobs.count && (try encoder.encode(state.jobs)) == (try encoder.encode(copy.state.jobs)) && copy.launchCount == 0 && (try Data(contentsOf:standard)) == before,"仅复制读取正式状态到夹具；核对全部现有 UUID/状态/步骤/候选/尝试，不固定历史条数，不启动任何镜头")
                copy.shutdown()
            }
            try await StudioSelfTests.wait("preview diagnostics flushed",timeout:2) {
                guard let text = try? String(contentsOf:root.appendingPathComponent("preview-diagnostics.jsonl")) else { return false }
                return text.contains("discardedStale") && text.contains("cancelled") && text.contains("cacheHit")
            }
            let log = try String(contentsOf:root.appendingPathComponent("preview-diagnostics.jsonl"))
            let entries = try log.split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
            let allowed: Set<String> = ["date","version","requestID","scope","phase","elapsedMilliseconds","cacheHit","width","height","errorCode"]
            let requests = Set(entries.filter { $0["phase"] as? String == "requested" }.compactMap { $0["requestID"] as? String })
            let discarded = Set(entries.filter { $0["phase"] as? String == "discardedStale" }.compactMap { $0["requestID"] as? String })
            try check("诊断包含真实耗时且无敏感内容",entries.allSatisfy { Set($0.keys).isSubset(of:allowed) } && entries.contains { ($0["elapsedMilliseconds"] as? Double ?? 0) > 100 } && entries.contains { $0["errorCode"] != nil } && !discarded.isEmpty && discarded.isSubset(of:requests) && !log.contains(root.path) && !log.contains("private-name") && !log.contains("prompt"),"读取/耗时/取消/过期使用一致请求ID；不含文件路径、提示词或任务内容")
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print(error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("preview-test-report.json"),options:.atomic) }
        return checks.contains(where:{ !$0.passed }) ? 1 : 0
    }
}
