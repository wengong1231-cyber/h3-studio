import Foundation

extension TaskStore {
    var staticAssets: [H3StaticAsset] { (state.h3StaticCatalogs ?? []).flatMap(\.assets) }
    @discardableResult func importStaticCatalog(_ url: URL) async throws -> Int {
        guard !shuttingDown,!abConfigurationBusy,storageFault == nil else { throw StudioError.invalid("正在记录任务，请稍后再导入图库。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        configurationReadOperation = "核对完整静态图库 · 每张图片 SHA 与完整解码"
        let (bytes,assets) = try await Task.detached(priority:.utility) { try H3StaticCatalogReader.read(url) }.value
        guard !shuttingDown else { throw StudioError.invalid("应用已退出，图库未登记。") }
        let hash = H3ABConfigurationReader.digest(bytes)
        if state.h3StaticCatalogs?.contains(where:{ $0.id == hash }) == true { return 0 }
        guard (state.h3StaticCatalogs ?? []).count < 32 else { throw StudioError.invalid("图库记录已达上限。") }
        let directory = root.appendingPathComponent("h3-static-catalogs/" + hash),snapshot = directory.appendingPathComponent("handoff.json")
        _ = try H3Files.inside(snapshot.path,root.path + "/h3-static-catalogs")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:snapshot.path) {
            guard try H3Files.read(snapshot,limit:2_097_152) == bytes else { throw StudioError.invalid("图库历史快照指纹不一致。") }
        } else { try bytes.write(to:snapshot,options:.withoutOverwriting) }
        let before = state
        if state.h3StaticCatalogs == nil { state.h3StaticCatalogs = [] }
        state.h3StaticCatalogs?.append(.init(id:hash,sourcePath:url.path,snapshotPath:snapshot.path,importedAt:Date(),assets:assets))
        persist();guard storageFault == nil else { state = before;throw StudioError.invalid(storageFault!) }
        notice = "已登记 \(assets.count) 张完整图，指纹与解码通过。绑定任务后由助手检查实际原图和归一图，没有启动 GPU。"
        return assets.count
    }
    func canBindStaticInput(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.supersededBy == nil,
              job.externalHistory == nil,job.engine == .h3,job.h3QueuePlan != nil,job.h3Binding == nil,job.attempts.isEmpty,
              [.blocked,.failed,.cancelled,.interrupted].contains(job.status) else { return false }
        return !state.jobs.contains { $0.supersededBy == nil && $0.h3QueuePlan?.shot == job.shot &&
            ($0.h3QueuePlan?.part ?? 0) > job.h3QueuePlan!.part && (!$0.attempts.isEmpty || $0.h3Binding != nil) }
    }
    @discardableResult func bindStaticInput(_ id: UUID,primary: H3StaticAsset,references: [H3StaticAsset] = [],prompt: String,
                                           sourceReference: String,phaseAllocation: H3StaticStageAllocation? = nil,prepare: Bool = true) async throws -> H3StaticInputBinding {
        guard canBindStaticInput(id),let original = state.jobs.first(where:{ $0.id == id }),let plan = original.h3QueuePlan,
              primary.shot == plan.shot,references.count <= 4,references.allSatisfy({ $0.shot == plan.shot }),
              Set(([primary]+references).map(\.id)).count == references.count+1,(12...32768).contains(prompt.utf8.count),
              (8...2000).contains(sourceReference.utf8.count) else { throw StudioError.invalid("静态输入只能绑定未领取任务；已执行的镜头需先整镜重做。") }
        if plan.shot == 5 && plan.dependencyRequestID != nil {
            throw StudioError.invalid("S05 睁眼续段必须采用前段已接受的闭目端帧；睁眼静态图只能绑定为参考。")
        }
        if let phaseAllocation { try phaseAllocation.validate() }
        let allocationEncoder = JSONEncoder();allocationEncoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let allocationHash = try phaseAllocation.map { H3ABConfigurationReader.digest(try allocationEncoder.encode($0)) }
        if let current = original.h3StaticBinding,current.primary == primary,current.motionReferences == references,
           current.promptSHA256 == H3ABConfigurationReader.digest(Data(prompt.utf8)),current.phaseAllocationSHA256 == allocationHash {
            if prepare { await startPlannedJob(id) };return current
        }
        abConfigurationBusy = true;configurationReadOperation = "记录 \(original.shortID) 完整静态图修订与旧输入历史"
        let workspace = root
        let affected = state.jobs.filter { $0.supersededBy == nil && $0.h3QueuePlan?.shot == plan.shot && ($0.h3QueuePlan?.part ?? 0) >= plan.part }
        let binding: H3StaticInputBinding
        do {
            binding = try await Task.detached(priority:.utility) {
                _ = try primary.readVerified();for reference in references { _ = try reference.readVerified() }
                let key = UUID(),directory = workspace.appendingPathComponent("h3-config/" + id.uuidString + "/static-inputs/" + key.uuidString)
                _ = try H3Files.inside(directory.path,workspace.path + "/h3-config")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                let prior = try encoder.encode(original),priorHash = H3ABConfigurationReader.digest(prior)
                try prior.write(to:directory.appendingPathComponent("previous-job.json"),options:.withoutOverwriting)
                try encoder.encode(affected).write(to:directory.appendingPathComponent("previous-dependent-jobs.json"),options:.withoutOverwriting)
                var allocationPath: String?,allocationHash: String?
                if let phaseAllocation {
                    try phaseAllocation.validate()
                    guard phaseAllocation.assignments.contains(where:{ $0.plan == plan && $0.asset == primary &&
                        ($0.motionReferences ?? []) == references && $0.effectivePrompt == prompt }) else { throw StudioError.invalid("静态图、参考与提示词不属于已声明阶段分段。") }
                    let bytes = try encoder.encode(phaseAllocation),hash = H3ABConfigurationReader.digest(bytes)
                    let path = workspace.appendingPathComponent("h3-static-stage-plans/" + hash + ".json")
                    try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
                    if FileManager.default.fileExists(atPath:path.path) { guard try H3Files.read(path) == bytes else { throw StudioError.invalid("阶段记录变化。") } }
                    else { try bytes.write(to:path,options:.withoutOverwriting) }
                    allocationPath = path.path;allocationHash = hash
                }
                let record = H3StaticInputRecord(bindingID:key,appJobID:id,workspace:workspace.path,plan:plan,primary:primary,
                    motionReferences:references,prompt:prompt,sourceReference:sourceReference,createdAt:Date(),previousJobSHA256:priorHash,
                    phaseAllocationPath:allocationPath,phaseAllocationSHA256:allocationHash)
                let bytes = try encoder.encode(record)
                try bytes.write(to:directory.appendingPathComponent("binding.json"),options:.withoutOverwriting)
                try Data(prompt.utf8).write(to:directory.appendingPathComponent("prompt.txt"),options:.withoutOverwriting)
                return .init(id:key,appJobID:id,directory:directory.path,recordSHA256:H3ABConfigurationReader.digest(bytes),
                    primary:primary,motionReferences:references,promptSHA256:H3ABConfigurationReader.digest(Data(prompt.utf8)),
                    previousJobSHA256:priorHash,phaseAllocationPath:allocationPath,phaseAllocationSHA256:allocationHash)
            }.value
            guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].h3Binding == nil,
                  state.jobs[i].attempts.isEmpty,state.jobs[i].supersededBy == nil,
                  state.jobs[i].h3FirstProposal == original.h3FirstProposal,state.jobs[i].h3StaticBinding == original.h3StaticBinding else {
                throw StudioError.invalid("任务已改变，静态输入修订仅暂存，没有接续。")
            }
            let before = state
            for j in state.jobs.indices where state.jobs[j].supersededBy == nil && state.jobs[j].h3QueuePlan?.shot == plan.shot && (state.jobs[j].h3QueuePlan?.part ?? 0) >= plan.part {
                let remainedCancelled = state.jobs[j].status == .cancelled
                state.jobs[j].h3FirstProposal = nil;state.jobs[j].h3AutomaticWorkflow = nil;state.jobs[j].h3VideoReview = nil
                state.jobs[j].executionActivity = nil;state.jobs[j].progress = nil;state.jobs[j].startedAt = nil;state.jobs[j].endedAt = nil
                state.jobs[j].status = remainedCancelled ? .cancelled : .blocked;state.jobs[j].error = nil
                state.jobs[j].h3InputPreparation = .init(materialsStartedAt:Date(),materialsEndedAt:Date())
                state.jobs[j].stage = j == i ? "完整静态图已绑定 · 待 CPU 归一化与助手检查" : "前段输入已修订 · 旧端帧与旧 QA 不再放行"
                if remainedCancelled { state.jobs[j].stage = "已取消 · 输入修订已记录，未恢复任务";state.jobs[j].endedAt = before.jobs[j].endedAt }
                state.jobs[j].logTail.append("输入修订 \(binding.id.uuidString)：原状态、提案与依赖记录保存在 \(binding.directory)。旧图片、QA、清单与候选不覆盖。")
            }
            state.jobs[i].h3StaticBinding = binding;state.jobs[i].reference = primary.path;state.jobs[i].prompt = prompt
            selectedID = id;persist()
            guard storageFault == nil else { state = before;throw StudioError.invalid(storageFault!) }
            abConfigurationBusy = false
        } catch { abConfigurationBusy = false;throw error }
        if prepare { await startPlannedJob(id) }
        return binding
    }
    /// Explicit stage allocation is supplied separately from the image pack.
    /// Register all choices before preparing any segment; no guessed S05 cuts.
    func bindStaticStageAllocation(_ allocation: H3StaticStageAllocation) async throws {
        try allocation.validate()
        guard singleGeneratorIdle else { throw StudioError.invalid("现有任务正在运行，阶段映射未改变。") }
        for plan in allocation.allPlans {
            guard let job = currentPlannedJob(plan.requestID),job.h3QueuePlan == plan,
                  canBindStaticInput(job.id) else { throw StudioError.invalid("阶段映射必须对应当前全部未领取任务。") }
        }
        guard allocation.assignments.allSatisfy({ $0.plan.dependencyRequestID == nil }),
              (allocation.preservedPlans ?? []).allSatisfy({ currentPlannedJob($0.requestID)?.h3StaticBinding == nil }) else {
            throw StudioError.invalid("阶段映射不能用静态终态替换续段首帧，也不能覆盖要保留的原来源。")
        }
        // Verify every static asset before any production state changes.
        try await Task.detached(priority:.utility) {
            for assignment in allocation.assignments {
                _ = try assignment.asset.readVerified()
                for reference in assignment.motionReferences ?? [] { _ = try reference.readVerified() }
            }
        }.value
        let before = state
        do {
        for assignment in allocation.assignments.sorted(by:{ $0.plan.part < $1.plan.part }) {
            let job = currentPlannedJob(assignment.plan.requestID)!
            _ = try await bindStaticInput(job.id,primary:assignment.asset,references:assignment.motionReferences ?? [],prompt:assignment.effectivePrompt,
                sourceReference:allocation.sourceReference,phaseAllocation:allocation,prepare:false)
        }
        if let first = allocation.assignments.first,let binding = currentPlannedJob(first.plan.requestID)?.h3StaticBinding {
            for plan in allocation.preservedPlans ?? [] {
                if let i = state.jobs.firstIndex(where:{ $0.supersededBy == nil && $0.h3QueuePlan == plan }) {
                    let entry = "S05 阶段映射保留本段原输入来源与依赖：" + (binding.phaseAllocationPath ?? "")
                    if !state.jobs[i].logTail.contains(entry) { state.jobs[i].logTail.append(entry) }
                }
            }
            persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        }
        } catch { state = before;persist();throw error }
        notice = "S05 阶段映射已登记；保留276帧窗口、原片切点和续段端点依赖，未启动生成。"
    }
    func canRedoEntireShot(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),let plan = job.h3QueuePlan,
              job.supersededBy == nil,job.externalHistory == nil,state.jobs.count+plan.partCount <= 2000 else { return false }
        let current = state.jobs.filter { $0.supersededBy == nil && $0.externalHistory == nil && $0.h3QueuePlan?.shot == plan.shot }
        return current.count == plan.partCount && current.contains(where:{ !$0.attempts.isEmpty || $0.h3Binding != nil || $0.redoOf == nil })
    }
    @discardableResult func redoEntireShot(_ id: UUID,reason: String,sourceReference: String) throws -> [UUID] {
        guard canRedoEntireShot(id),let job = state.jobs.first(where:{ $0.id == id }),let plan = job.h3QueuePlan,
              (8...4000).contains(reason.utf8.count),(8...2000).contains(sourceReference.utf8.count) else { throw StudioError.invalid("整镜重做需要当前镜号、明确原因与操作来源；现有运行不能中途替换。") }
        let previous = state,selection = selectedID
        let current = state.jobs.filter { $0.supersededBy == nil && $0.externalHistory == nil && $0.h3QueuePlan?.shot == plan.shot }.sorted { $0.h3QueuePlan!.part < $1.h3QueuePlan!.part }
        var created: [ShotJob] = []
        for old in current {
            var next = ShotJob(shot:old.shot,segment:old.segment,title:old.title + " · 整镜重做",prompt:old.prompt,
                requestedDuration:old.requestedDuration,engine:.h3,status:.blocked)
            next.h3QueuePlan = old.h3QueuePlan;next.parameters = old.parameters;next.parameters.verified = false
            next.redoOf = old.id;next.importKey = "whole-shot-redo:" + next.id.uuidString
            next.requiresNewStaticInput = old.h3QueuePlan!.part == 1
            next.stage = old.h3QueuePlan!.part == 1 ? "整镜重做 · 等待新完整首图绑定" : "整镜重做 · 等待新前段输出与可信接受来源"
            next.logTail = ["整镜重做操作：" + reason,"操作来源：" + sourceReference + "；此记录不声明操作者为用户。","原视频、原验收和原QA保留；新任务不会继承旧接受或旧端帧。"]
            if let i = state.jobs.firstIndex(where:{ $0.id == old.id }) {
                state.jobs[i].supersededBy = next.id;state.jobs[i].h3VideoReview?.status = "superseded"
                state.jobs[i].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
                if state.jobs[i].status.isPending {
                    state.jobs[i].status = .cancelled;state.jobs[i].stage = "整镜重做 · 原依赖已撤销";state.jobs[i].endedAt = Date()
                    state.jobs[i].h3AutomaticWorkflow?.status = "cancelled";state.jobs[i].progress = nil
                }
            }
            created.append(next)
        }
        state.jobs.append(contentsOf:created);selectedID = created.first?.id;persist()
        guard storageFault == nil else { state = previous;selectedID = selection;throw StudioError.invalid(storageFault!) }
        notice = "已登记 \(created.count) 段整镜重做，原候选与历史保留；绑定新首图后才准备，没有启动 GPU。"
        return created.map(\.id)
    }
}
