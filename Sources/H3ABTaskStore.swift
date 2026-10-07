import Foundation

extension TaskStore {
    @discardableResult func importS41Configuration(_ url: URL, newAttempt: Bool = false) async throws -> UUID {
        guard !shuttingDown,!abConfigurationBusy,abWorkflowID == nil,storageFault == nil else { throw StudioError.invalid("正在核对配置或执行自动流程，请稍后再导入。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let materialsStarted = Date()
        let runtime = h3Runtime
        let read = try await Task.detached(priority:.utility) { try H3ABConfigurationReader.load(url,workDirectory:runtime.workDirectory,mock:runtime.mode == .mock) }.value
        guard !shuttingDown else { throw StudioError.invalid("应用已开始退出，未修改任务。") }
        let key = "app-s41-config:" + H3ABConfigurationReader.digest(Data(url.path.utf8))
        if !newAttempt,let index = state.jobs.lastIndex(where: { $0.importKey == key && $0.h3ABConfiguration != nil }) {
            guard state.jobs[index].status.isPending,state.jobs[index].attempts.isEmpty,state.jobs[index].h3Binding == nil else {
                selectedID = state.jobs[index].id;notice = "该配置已有任务；旧尝试保留，需要重做时请明确创建新的尝试。";return state.jobs[index].id
            }
            let id = state.jobs[index].id
            if let existing = state.jobs[index].h3ABConfiguration,let originalHash = existing.originalProposalSHA256 {
                guard originalHash == read.configuration.sourceSHA256 else { throw StudioError.invalid("原提案在 App 准备 A/B 后已改变；本任务保留，请明确创建新尝试。") }
                selectedID = id;notice = "原提案指纹一致；保留 App 已准备与检查的 A/B，没有重复添加或启动。";return id
            }
            if state.jobs[index].h3ABConfiguration?.sourceSHA256 != read.configuration.sourceSHA256 { try saveS41Configuration(read,index:index) }
            selectedID = id;notice = "S41 配置已在队列中；没有重复添加或自动启动。";return id
        }
        guard state.jobs.count < 2000 else { throw StudioError.invalid("工作区已达到记录上限。") }
        var job = ShotJob(shot:41,segment:"s41-p01",title:h3Runtime.mode == .mock ? "S41 · A/B CPU 协议验证" : "S41 · 新 A/B 出水与收势",prompt:read.configuration.prompt ?? "",reference:read.configuration.first.normalizedPath,lastReference:read.configuration.last.normalizedPath,requestedDuration:3,engine:.h3,status:.blocked)
        job.h3InputPreparation = .init(materialsStartedAt:materialsStarted,materialsEndedAt:Date())
        job.importKey = key;job.parameters = .init(width:768,height:448,frames:73,steps:4,fps:24,model:h3Runtime.mode == .mock ? "CPU mock · S41 A/B 协议" : "MiniMax H3 FL2VA 8-bit / Turbo LoRA v4",verified:false)
        let index = state.jobs.count;state.jobs.append(job)
        do { try saveS41Configuration(read,index:index) }
        catch { state.jobs.remove(at:index);throw error }
        selectedID = job.id;state.queuePaused = true;persist()
        guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "S41 独立任务已登记。原生 73 帧，成片目标 72 帧；导入没有启动生成。"
        return job.id
    }
    func saveS41Configuration(_ read: H3ABConfigurationRead,index: Int) throws {
        var configuration = read.configuration
        configuration.revision = (state.jobs[index].h3ABConfiguration?.revision ?? 0) + 1
        let directory = root.appendingPathComponent("h3-config/" + state.jobs[index].id.uuidString,isDirectory:true)
        _ = try H3Files.inside(directory.path,root.path + "/h3-config")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let snapshot = directory.appendingPathComponent("revision-\(configuration.revision).json")
        try read.data.write(to:snapshot,options:.withoutOverwriting)
        guard try WorkspaceDigest.sha256(snapshot) == configuration.sourceSHA256 else { throw StudioError.invalid("S41 配置保存校验失败。") }
        configuration.snapshotPath = snapshot.path
        state.jobs[index].h3ABConfiguration = configuration;state.jobs[index].reference = configuration.first.normalizedPath;state.jobs[index].lastReference = configuration.last.normalizedPath
        state.jobs[index].prompt = configuration.prompt ?? "";state.jobs[index].stage = configuration.stage;state.jobs[index].error = nil;state.jobs[index].progress = nil
        state.jobs[index].updatedAt = Date();state.jobs[index].logTail.append("App 已保存 S41 配置第 \(configuration.revision) 版，SHA-256 \(configuration.sourceSHA256)。A→port5，B→port6；原生73帧/24fps，raw72在3.000秒；成片72帧/3秒另行导出。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
    }
    func refreshS41Configuration(_ id: UUID) async {
        guard let job = state.jobs.first(where:{ $0.id == id }),let configuration = job.h3ABConfiguration,job.status.isPending,job.attempts.isEmpty,job.h3Binding == nil else { return }
        do { _ = try await importS41Configuration(URL(fileURLWithPath:configuration.sourcePath)) }
        catch { notice = error.localizedDescription }
    }
    func createS41RetryTask(_ id: UUID) async {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),let configuration = job.h3ABConfiguration,
              job.status.canRetry || job.h3InputPreparation?.status == "failed" else { return }
        do {
            _ = try await importS41Configuration(URL(fileURLWithPath:configuration.sourcePath),newAttempt:true)
            if job.status.isPending { cancel(id,source:"user explicitly created a new preparation attempt") }
            notice = "已登记新的 S41 重试任务；开始一次后自动处理与生成，原步骤、图片与候选保留。"
        } catch { notice = error.localizedDescription }
    }
    func canPrepareS41(_ id: UUID) -> Bool {
        guard let job = state.jobs.first(where:{ $0.id == id }),let configuration = job.h3ABConfiguration else { return false }
        return canUseS41Resources(id) && job.status.isPending && job.attempts.isEmpty && job.h3Binding == nil && configuration.launchAuthorized && configuration.blockers.isEmpty && configuration.automaticInputsValidated
    }
    func materializeS41(_ id: UUID) async throws -> H3Binding {
        guard canPrepareS41(id),let configuration = state.jobs.first(where:{ $0.id == id })?.h3ABConfiguration else { throw StudioError.invalid("S41 配置未齐、资源尚未空闲或已有尝试。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let workspace = root,executable = self.executable,runtime = h3Runtime
        let (binding,_) = try await Task.detached(priority:.utility) { try H3ABTaskBinding.materialize(jobID:id,workspace:workspace,configuration:configuration,executable:executable,runtime:runtime) }.value
        guard !shuttingDown,let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status.isPending,state.jobs[index].h3ABConfiguration == configuration else { throw StudioError.invalid("S41 材料化期间任务状态变化；未执行，已准备文件保留。") }
        state.jobs[index].h3Binding = binding;state.jobs[index].stage = "S41 A/B 输入已冻结 · 等待本次生成"
        state.jobs[index].logTail.append("App 创建全新单镜 \(binding.nativeJobID)，任务与管线指纹已保存；没有复用旧 S41 或 S15 的尝试。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        return binding
    }
}
