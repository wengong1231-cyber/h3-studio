import Foundation

extension TaskStore {
    func canPreparePlannedJob(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }) else { return false }
        return plannedReadiness(job).ready
    }
    func prepareNextPlannedJob() async {
        let candidates = plannedPreparationCandidates
        for job in candidates {
            guard singleGeneratorIdle else { return }
            await startPlannedJob(job.id)
            if activeJob != nil || state.jobs.first(where:{ $0.id == job.id })?.h3AutomaticWorkflow?.phase == "pixel_qa" { return }
        }
        notice = "没有可准备的段；缺首帧审核或前段认可的任务保持等待。"
    }
    func startPlannedJob(_ id: UUID,mockScenario: String? = nil) async {
        guard singleGeneratorIdle,let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status.isPending,
              state.jobs[index].externalHistory == nil,state.jobs[index].supersededBy == nil,state.jobs[index].attempts.isEmpty,state.jobs[index].h3Binding == nil else { return }
        if state.jobs[index].requiresNewStaticInput == true && state.jobs[index].h3StaticBinding == nil {
            notice = "整镜重做需绑定新完整首图，未沿用旧母片输入。";return
        }
        if state.jobs[index].h3StaticBinding?.hasRequiredPhaseAllocation == false {
            notice = "S05 的三阶段边界尚未同步，完整图已登记，没有生成。";return
        }
        if state.jobs[index].h3FirstProposal != nil { await startAuthorizedFirst(id);return }
        guard let plan = state.jobs[index].h3QueuePlan else { return }
        let original = state.jobs[index],prior = plan.dependencyRequestID.flatMap { request in currentPlannedJob(request) }
        let workspace = root,runtime = h3Runtime
        configurationReadOperation = "核对 \(original.shortID) 第\(plan.part)段输入来源与参数"
        abConfigurationBusy = true
        do {
            let proposal = try await Task.detached(priority:.utility) {
                let data = try H3QueueExecution.descriptor(job:original,predecessor:prior,workspace:workspace,runtime:runtime,mockScenario:mockScenario)
                let directory = original.h3StaticBinding.map { URL(fileURLWithPath:$0.directory) } ?? workspace.appendingPathComponent("h3-config/" + id.uuidString)
                _ = try H3Files.inside(directory.path,workspace.path + "/h3-config")
                let path = directory.appendingPathComponent("queue-proposal.json")
                var proposal = try H3QueueExecution.parse(data,sourcePath:path.path,runtime:runtime).proposal
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                if FileManager.default.fileExists(atPath:path.path) {
                    guard try H3Files.read(path) == data else { throw StudioError.invalid("同一队列任务已有不同配置，保留原输入。") }
                } else { try data.write(to:path,options:.withoutOverwriting) }
                proposal.snapshotPath = path.path;return proposal
            }.value
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending,
                  state.jobs[current].h3FirstProposal == nil else { abConfigurationBusy = false;return }
            state.jobs[current].h3FirstProposal = proposal
            state.jobs[current].h3InputPreparation = .init(materialsStartedAt:Date(),materialsEndedAt:Date())
            state.jobs[current].parameters.verified = false;state.jobs[current].error = nil
            state.jobs[current].stage = "队列段已绑定 · 准备实际输入"
            state.jobs[current].logTail.append("按清单绑定第 \(plan.part) 段，原生 \(plan.profile.frames) 帧、选择[\(plan.selectedRawStart),\(plan.selectedRawEnd))，没有替换旧 PNG 或启动其他段。")
            persist();abConfigurationBusy = false
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            await startAuthorizedFirst(id)
        } catch {
            abConfigurationBusy = false
            guard let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending else { return }
            state.jobs[current].stage = plan.dependencyRequestID == nil ? "输入绑定失败 · 未进入 GPU" : "等待前段审核与精确端点"
            if plan.dependencyRequestID == nil {
                state.jobs[current].status = .failed;state.jobs[current].endedAt = Date()
            }
            state.jobs[current].error = error.localizedDescription
            state.jobs[current].logTail.append(error.localizedDescription);persist()
        }
    }
}
