import Foundation

@MainActor enum H3QueueSelfTests {
    static func canonical(_ jobs: [ShotJob]) throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(jobs)
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            let fm = FileManager.default;try fm.createDirectory(at:root,withIntermediateDirectories:true)
            let liveState = WorkspaceMigrator.defaultSupportRoot.appendingPathComponent("Workspace/state.json")
            let originalData = try H3Files.read(liveState),originalHash = H3ABConfigurationReader.digest(originalData)
            let original = try JSONDecoder().decode(WorkspaceState.self,from:originalData)
            guard !original.jobs.contains(where:{ $0.status.isActive }) else { throw StudioError.invalid("真实生成正在运行，不能作为静态导入测试基线。") }
            // Exercise first import with existing unrelated history, and current
            // production replay separately. Neither depends on a historical count.
            var baseline = original;baseline.jobs = original.jobs.filter { $0.h3QueuePlan == nil }
            let historyCount = baseline.jobs.count,expectedCount = historyCount + 33
            let canonicalBefore = try canonical(baseline.jobs)
            let liveCopyRoot = root.appendingPathComponent("current-records")
            try fm.createDirectory(at:liveCopyRoot,withIntermediateDirectories:true)
            try originalData.write(to:liveCopyRoot.appendingPathComponent("state.json"),options:.withoutOverwriting)
            let liveCopy = try TaskStore(root:liveCopyRoot,executable:executable,monitoring:false,h3Runtime:.real)
            let currentBefore = try canonical(liveCopy.state.jobs)
            let alreadyPlanned = original.jobs.contains { $0.h3QueuePlan != nil }
            let currentAdded = try await liveCopy.importPlannedQueue(H3QueuePlan.knownPath)
            if alreadyPlanned {
                try check("现有计划重入不复制或丢失历史",currentAdded == 0 && (try canonical(liveCopy.state.jobs)) == currentBefore && liveCopy.launchCount == 0,"全部现有任务与重做关系逐项不变，生产工作区只读")
            }
            liveCopy.shutdown()
            let workspace = root.appendingPathComponent("workspace");try fm.createDirectory(at:workspace,withIntermediateDirectories:true)
            try JSONEncoder().encode(baseline).write(to:workspace.appendingPathComponent("state.json"),options:.withoutOverwriting)
            let store = try TaskStore(root:workspace,executable:executable,monitoring:false,h3Runtime:.real)
            let reader = try H3QueueReader.load(H3QueuePlan.knownPath,runtime:.real)
            try check("已核清单17镜33段",reader.jobs.count == 33 && Set(reader.jobs.map(\.shot)).count == 17 && reader.jobs[0].shot == 19,"read-only actual manifest, actual33 prompt hashes and17 identity reference hashes")
            try check("首段和依赖待办分开",reader.jobs.contains { $0.h3QueuePlan?.dependencyRequestID == nil } && reader.jobs.contains { $0.displayStatusLabel == "等待前段" },"待准备与前段精确端点依赖可见，不冒称可执行")
            try check("认可和锁定镜头未重入",!reader.jobs.contains { [15,40,41].contains($0.shot) },"S15/S41/S40 exclusions retained")
            let count = try await store.importPlannedQueue(H3QueuePlan.knownPath)
            try check("App入口实际创建可见待办",count == 33 && store.state.jobs.count == expectedCount && store.state.jobs.filter { $0.h3QueuePlan != nil }.count == 33,"isolated App workspace contains retained unrelated history plus33 planned rows")
            try check("已有无关历史逐项保持",try canonical(Array(store.state.jobs.prefix(historyCount))) == canonicalBefore,"all original fields, IDs, output paths and acceptance flags unchanged")
            try check("清单导入没有执行",store.launchCount == 0 && store.activeJob == nil && store.state.jobs.suffix(33).allSatisfy { $0.status == .blocked && $0.h3Binding == nil && $0.reference == nil && !$0.parameters.verified },
                "旧 PNG 未绑定实际生成输入，所有计划无 native binding")
            let duplicate = try await store.importPlannedQueue(H3QueuePlan.knownPath)
            try check("重复导入去重",duplicate == 0 && store.state.jobs.count == expectedCount,"stable request IDs prevent duplicate rows")
            try check("身份参考与实际首帧区分",reader.jobs.allSatisfy { $0.h3QueuePlan?.identityReferenceMatches == true && $0.reference == nil },
                "17 original PNG identities checked; actual current frames still missing")
            let firstID = store.state.jobs.first { $0.h3QueuePlan?.shot == 19 && $0.h3QueuePlan?.part == 1 }!.id
            let upgraded = try await store.importFirstProposal(H3FirstProposal.knownPath)
            try check("S19绑定升级原待办",upgraded == firstID && store.state.jobs.count == expectedCount && store.state.jobs.first { $0.id == firstID }?.h3FirstProposal?.sourceFrameIndex == 3248 && store.launchCount == 0,
                "same App ID, actual current source contract; no second S19p01 or source extraction in queue test")
            let afterUpgrade = try await store.importPlannedQueue(H3QueuePlan.knownPath)
            try check("升级后再次导入不重复",afterUpgrade == 0 && store.state.jobs.count == expectedCount,"planned request identity retained after first-frame proposal binding")
            let blocked = store.state.jobs.first { $0.h3QueuePlan?.shot == 35 && $0.h3QueuePlan?.part == 1 }!.id
            store.cancel(blocked,source:"queue fixture cancellation")
            _ = try await store.importPlannedQueue(H3QueuePlan.knownPath)
            try check("取消待办不被重新导入复活",store.state.jobs.first { $0.id == blocked }?.status == .cancelled && store.launchCount == 0,"cancelled plan remains cancelled with its immutable ID")
            var wrong = try JSONSerialization.jsonObject(with:reader.data) as! [String:Any]
            var items = wrong["items"] as! [[String:Any]],parts = items[0]["parts"] as! [[String:Any]],input = parts[1]["first_image"] as! [String:Any]
            input["source_raw_index"] = 82;parts[1]["first_image"] = input;items[0]["parts"] = parts;wrong["items"] = items
            let invalidEndpoint = (try? H3QueueReader.parse(JSONSerialization.data(withJSONObject:wrong),runtime:.real)) == nil
            try check("错误续段端点阻塞",invalidEndpoint,"S19p02 must bind selected prior raw83, never raw82")
            wrong = try JSONSerialization.jsonObject(with:reader.data) as! [String:Any]
            items = wrong["items"] as! [[String:Any]];parts = items[0]["parts"] as! [[String:Any]]
            parts[0]["native_launch_ready"] = true;items[0]["parts"] = parts;wrong["items"] = items
            try check("未准备输入不能伪装可生成",(try? H3QueueReader.parse(JSONSerialization.data(withJSONObject:wrong),runtime:.real)) == nil,"preparation-only manifest rejects a forged ready flag")
            let saved = try H3Files.read(workspace.appendingPathComponent("state.json"))
            let restoredRoot = root.appendingPathComponent("restored");try fm.createDirectory(at:restoredRoot,withIntermediateDirectories:true)
            try saved.write(to:restoredRoot.appendingPathComponent("state.json"))
            let restored = try TaskStore(root:restoredRoot,executable:executable,monitoring:false,h3Runtime:.real)
            try check("待办重启持久化",restored.state.jobs.count == expectedCount && restored.state.jobs.filter { $0.h3QueuePlan?.dependencyRequestID != nil && $0.status == .blocked }.count > 0 && restored.launchCount == 0,
                "all IDs, pending dependencies and cancellation recovered without workers")
            try check("生产工作区未被测试修改",H3ABConfigurationReader.digest(try H3Files.read(liveState)) == originalHash,
                "actual current workspace read only; all import writes stayed in isolated test root")
            restored.shutdown();store.shutdown()
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print("FAIL " + error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains { !$0.passed } ? 1 : 0
    }
}
