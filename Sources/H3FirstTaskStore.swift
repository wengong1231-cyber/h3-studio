import Foundation

extension TaskStore {
    @discardableResult func importFirstProposal(_ url: URL) async throws -> UUID {
        guard !shuttingDown,!abConfigurationBusy,abWorkflowID == nil,storageFault == nil else { throw StudioError.invalid("正在处理任务，请稍后再导入首帧提案。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let started = Date(),runtime = h3Runtime
        let read = try await Task.detached(priority:.utility) { try H3FirstProposalReader.load(url,runtime:runtime) }.value
        guard !shuttingDown else { throw StudioError.invalid("应用已开始退出，未登记任务。") }
        let key = "app-first-proposal:" + read.proposal.proposalID
        if let existing = state.jobs.first(where:{ $0.importKey == key }) {
            guard existing.h3FirstProposal?.sourceSHA256 == read.proposal.sourceSHA256 else { throw StudioError.invalid("此提案身份已存在且内容变化；保留原任务，需要新的提案身份。") }
            selectedID = existing.id;notice = "S19 提案已登记，保留原任务与产物，没有重复添加或启动。";return existing.id
        }
        guard state.jobs.count < 2000 else { throw StudioError.invalid("工作区已达到记录上限。") }
        let plannedIndex = state.jobs.firstIndex(where:{ $0.externalHistory == nil && $0.h3FirstProposal == nil
            && $0.h3QueuePlan?.shot == read.proposal.shot && $0.h3QueuePlan?.part == read.proposal.part
            && $0.h3QueuePlan?.detailedFirstContractPath == url.path && $0.status.isPending && $0.attempts.isEmpty })
        var job = plannedIndex.map { state.jobs[$0] } ?? ShotJob(shot:read.proposal.shot,segment:read.proposal.segment,title:"S19 · 自然前行 · 首段",
            prompt:read.proposal.prompt,requestedDuration:Double(read.proposal.targetFrames)/24,engine:.h3,status:.blocked)
        let directory = root.appendingPathComponent("h3-config/" + job.id.uuidString)
        _ = try H3Files.inside(directory.path,root.path + "/h3-config")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let snapshot = directory.appendingPathComponent("first-proposal.json")
        try read.data.write(to:snapshot,options:.withoutOverwriting)
        guard try WorkspaceDigest.sha256(snapshot) == read.proposal.sourceSHA256 else { throw StudioError.invalid("首帧提案快照保存校验失败。") }
        var proposal = read.proposal;proposal.snapshotPath = snapshot.path
        job.h3FirstProposal = proposal;job.importKey = key;job.stage = "就绪后提取实际源帧、检查画面并生成"
        job.h3InputPreparation = .init(materialsStartedAt:started,materialsEndedAt:Date())
        job.parameters = .init(width:768,height:448,frames:90,steps:4,fps:24,
            model:runtime.mode == .mock ? "CPU mock · S19 首帧协议" : "MiniMax H3 FL2VA 8-bit / Turbo LoRA v4",verified:false)
        job.logTail.append("App 已登记独立 S19 p01；实际源帧 \(proposal.sourceFrameIndex)，A→port5，port6不连接，原生90帧，选择[0,84)另行处理。导入不会生成。")
        if let plannedIndex { state.jobs[plannedIndex] = job } else { state.jobs.append(job) }
        selectedID = job.id;state.queuePaused = true;persist()
        guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "S19 首段已登记；开始后自动提帧、完整画面归一化、检查与生成。"
        return job.id
    }
    func canStartFirstWorkflow(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }) else { return false }
        return dependencyBlocker(job,operation:.firstPreparation) == nil && QueueScheduling.firstReadiness(job).ready
    }
    func startAuthorizedFirst(_ id: UUID,resumeLaunches: Bool = true) async {
        guard canStartFirstWorkflow(id),let index = state.jobs.firstIndex(where:{ $0.id == id }),
              let proposal = state.jobs[index].h3FirstProposal else { return }
        // Only an explicit start resumes launches. Input repair may prepare a
        // new revision while preserving the user's existing queue pause.
        if resumeLaunches { state.automaticLaunchesPaused = false }
        abWorkflowID = id;defer { abWorkflowID = nil }
        let control = H3PreparationControl();abPreparationControl = control;abPreparationID = id
        defer {
            abPreparationID = nil;abPreparationControl = nil
            if let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].status == .cancelled { state.jobs[i].progress = nil;state.jobs[i].h3InputPreparation?.endedAt = Date();persist() }
        }
        let now = Date()
        state.jobs[index].startedAt = now
        state.jobs[index].h3AutomaticWorkflow = .init(status:"running",phase:proposal.isStaticInput ? "static_image_preparation" : "exact_frame_preparation",startedAt:now,automaticContinuationAuthorized:true)
        state.jobs[index].h3InputPreparation?.status = "running";state.jobs[index].h3InputPreparation?.startedAt = now
        state.jobs[index].stage = proposal.isStaticInput ? "检查完整静态图 · 准备实际首图" : "检查源视频 · 准备实际首帧";state.jobs[index].error = nil
        state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:now);persist()
        do {
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            let runtime = h3Runtime
            let input = try await Task.detached(priority:.utility) {
                let progress: H3SourceFrames.Progress = { [weak self] event in
                    await self?.recordFirstPreparationEvent(event,id:id)
                }
                if proposal.isStaticInput {
                    return try await H3SourceFrames.prepareStatic(proposal,jobID:id,control:control,progress:progress)
                }
                if proposal.queueExecution?.endpoint != nil {
                    return try await H3SourceFrames.prepareEndpoint(proposal,jobID:id,runtime:runtime,control:control,progress:progress)
                }
                return try await H3SourceFrames.prepare(proposal,jobID:id,control:control,progress:progress)
            }.value
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending,
                  state.jobs[current].h3FirstProposal == proposal else { return }
            state.jobs[current].h3FirstProposal?.input = input
            state.jobs[current].reference = input.normalizedPath
            state.jobs[current].h3InputPreparation?.status = "completed";state.jobs[current].h3InputPreparation?.endedAt = Date()
            state.jobs[current].h3InputPreparation?.receiptPath = input.extractionReceiptPath
            state.jobs[current].h3InputPreparation?.automaticValidationStatus = "completed"
            state.jobs[current].h3InputPreparation?.automaticValidationStartedAt = now
            state.jobs[current].h3InputPreparation?.automaticValidationEndedAt = Date()
            state.jobs[current].h3InputPreparation?.automaticValidationReceiptPath = input.extractionReceiptPath
            state.jobs[current].h3AutomaticWorkflow?.status = "waiting";state.jobs[current].h3AutomaticWorkflow?.phase = "pixel_qa"
            state.jobs[current].stage = proposal.isStaticInput ? "完整静态图已准备 · 助手检查原图、归一图与动作参考" : "源帧已准备 · 画面完整性检查中";state.jobs[current].progress = nil
            state.jobs[current].executionActivity?.milestone(state.jobs[current].stage,at:Date(),phase:.checkingInput)
            state.jobs[current].logTail.append("精确源帧与完整画面归一图实际写出，解码/尺寸/指纹技术检查通过。画面与提示词检查通过后自动接续，无需用户点击放行。")
            persist()
        } catch {
            guard let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending else { return }
            state.jobs[current].status = .failed;state.jobs[current].stage = "源帧准备失败 · 未进入 GPU"
            state.jobs[current].error = error.localizedDescription;state.jobs[current].endedAt = Date();state.jobs[current].progress = nil
            state.jobs[current].h3InputPreparation?.status = "failed";state.jobs[current].h3InputPreparation?.error = error.localizedDescription
            state.jobs[current].h3InputPreparation?.endedAt = Date();state.jobs[current].h3AutomaticWorkflow?.status = "failed"
            state.jobs[current].h3AutomaticWorkflow?.endedAt = Date();state.jobs[current].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
            state.jobs[current].executionActivity?.finish(.failed,stage:state.jobs[current].stage,at:state.jobs[current].endedAt!)
            notice = error.localizedDescription;persist()
        }
    }
    func recordFirstPreparationEvent(_ event: EngineEvent,id: UUID) {
        guard let index = state.jobs.firstIndex(where:{ $0.id == id }),let proposal = state.jobs[index].h3FirstProposal,
              abPreparationID == id else { return }
        if ["prepared_original","prepared_normalized","prepared_reference"].contains(event.type),let path = event.path,let hash = event.message,
           path.hasPrefix(proposal.workDirectory + "/app-inputs/App-source-frames/" + id.uuidString + "/"),
           ModelStatusReader.isHash(hash,length:64) {
            let role = event.type == "prepared_original" ? "original" : event.type == "prepared_reference" ? "motion_reference:" + URL(fileURLWithPath:path).lastPathComponent : "A"
            if state.jobs[index].h3InputPreparation?.images.contains(where:{ $0.role == role }) == false {
                state.jobs[index].h3InputPreparation?.images.append(.init(role:role,path:path,sha256:hash,writtenAt:Date()))
                state.jobs[index].logTail.append("App 实际保存 \(role == "A" ? "归一首帧" : "原始源帧")：SHA-256 \(hash)。")
            }
        }
        if state.jobs[index].status.isPending {
            if state.jobs[index].executionActivity == nil { state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:Date()) }
            state.jobs[index].executionActivity?.observe(event,at:Date())
            if let stage = event.stage,stage != state.jobs[index].stage { state.jobs[index].stage = stage;state.jobs[index].progress = nil }
            if event.type == "progress",let count = event.completed,let total = event.total,total > 0,count >= 0,count <= total {
                state.jobs[index].progress = .init(completed:count,total:total,unit:event.unit ?? "项")
            }
        }
        state.jobs[index].updatedAt = Date();persist()
    }
    func firstReviewURL(_ id: UUID) -> URL {
        if let rebind = state.jobs.first(where:{ $0.id == id })?.h3FirstProposal?.queueExecution?.receiptRebind {
            return URL(fileURLWithPath:rebind.reviewPath)
        }
        if let binding = state.jobs.first(where:{ $0.id == id })?.h3StaticBinding { return URL(fileURLWithPath:binding.reviewPath) }
        if let revision = state.jobs.first(where:{ $0.id == id })?.h3FirstProposal?.queueExecution?.actionRevision {
            return URL(fileURLWithPath:revision.reviewPath)
        }
        return root.appendingPathComponent("h3-config/" + id.uuidString + "/pixel-review.json")
    }
    func startBackgroundFirstProposals() {
        guard firstReviewTimer == nil,!shuttingDown else { return }
        firstReviewTimer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshQueueVideoReviews()
                await self?.checkFirstPixelReviews()
            }
        }
    }
    /// The assistant reads actual App previews and returns an immutable,
    /// task/hash-bound review. A review is never inferred from image metadata.
    func checkFirstPixelReviews() async {
        guard !firstReviewInFlight,singleGeneratorIdle else { return }
        let candidates = pixelReviewCandidates
        firstReviewInFlight = true;defer { firstReviewInFlight = false }
        for job in candidates {
            guard singleGeneratorIdle else { return }
            let id = job.id,url = firstReviewURL(id)
            do {
                let result: H3FirstPixelReview? = try await Task.detached(priority:.utility) {
                    _ = try H3Files.inside(url.path,url.deletingLastPathComponent().path)
                    guard FileManager.default.fileExists(atPath:url.path) else { return nil }
                    let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(H3FirstPixelReview.self,from:H3Files.read(url,limit:16384))
                }.value
                guard let result,!shuttingDown,let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status.isPending,
                      state.jobs[index].h3FirstProposal == job.h3FirstProposal else { continue }
                var updated = job.h3FirstProposal!;updated.pixelReview = result
                guard result.appJobID == id else { throw StudioError.invalid("画面检查回执属于其他 App 任务，未接续。") }
                guard updated.reviewBindingsMatch else { throw StudioError.invalid("画面检查没有绑定当前实际输入或提示词，未接续。") }
                if result.status == "fail" {
                    state.jobs[index].h3FirstProposal = updated
                    state.jobs[index].status = .failed;state.jobs[index].error = result.observation
                    state.jobs[index].stage = "输入画面需修复 · 未进入 GPU";state.jobs[index].endedAt = Date()
                    state.jobs[index].h3AutomaticWorkflow?.status = "failed";state.jobs[index].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
                    state.jobs[index].h3AutomaticWorkflow?.endedAt = Date()
                    state.jobs[index].executionActivity?.finish(.failed,stage:state.jobs[index].stage,at:state.jobs[index].endedAt!)
                    persist();continue
                }
                guard updated.reviewReady else { throw StudioError.invalid("画面检查未同时绑定实际原帧、归一图、提示词和提案指纹，未接续。") }
                if state.jobs[index].h3FirstProposal != updated || state.jobs[index].error != nil {
                    state.jobs[index].h3FirstProposal = updated;state.jobs[index].error = nil
                    state.jobs[index].stage = "画面检查通过 · 输入与回执保留"
                    state.jobs[index].executionActivity?.milestone(state.jobs[index].stage,at:Date(),phase:.preparing)
                    state.jobs[index].logTail.append("实际原帧、归一图与提示词检查通过，绑定当前任务及全部输入指纹。观察：" + result.observation)
                    persist()
                }
                await continueAuthorizedFirst(id)
                if activeJob != nil { return }
            } catch {
                guard let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status.isPending else { continue }
                if state.jobs[index].error != error.localizedDescription {
                    state.jobs[index].error = error.localizedDescription;state.jobs[index].stage = "画面检查记录不完整 · 未进入 GPU";persist()
                }
            }
        }
    }
    func resumeReboundFirst(_ id: UUID) async {
        guard singleGeneratorIdle,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].status.isPending,
              let proposal = state.jobs[i].h3FirstProposal,let rebind = proposal.queueExecution?.receiptRebind else { return }
        do {
            state.jobs[i].h3FirstProposal?.pixelReview = try rebind.bridgedReview(proposal:proposal)
            persist();guard storageFault == nil else { return }
            await continueAuthorizedFirst(id)
        } catch { notice = error.localizedDescription }
    }
    private func continueAuthorizedFirst(_ id: UUID) async {
        guard singleGeneratorIdle,state.automaticLaunchesPaused != true,let index = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[index].status.isPending,
              state.jobs[index].h3AutomaticWorkflow?.automaticContinuationAuthorized == true,
              let proposal = state.jobs[index].h3FirstProposal,proposal.reviewReady,
              dependencyBlocker(state.jobs[index],operation:.inputReview) == nil else { return }
        abWorkflowID = id;defer { abWorkflowID = nil }
        abConfigurationBusy = true
        state.jobs[index].h3AutomaticWorkflow?.status = "running";state.jobs[index].h3AutomaticWorkflow?.phase = "input_freeze";persist()
        do {
            let workspace = root,executable = self.executable,runtime = h3Runtime,existing = state.jobs[index].h3Binding
            let binding = try await Task.detached(priority:.utility) {
                if let existing { _ = try existing.revalidate();return existing }
                return try H3FirstTaskBinding.materialize(jobID:id,workspace:workspace,proposal:proposal,executable:executable,runtime:runtime)
            }.value
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending,
                  state.jobs[current].h3FirstProposal == proposal else { abConfigurationBusy = false;return }
            state.jobs[current].h3Binding = binding;persist()
            abConfigurationBusy = false
            if state.automaticLaunchesPaused == true || dependencyBlocker(state.jobs[current],operation:.nativeGeneration) != nil {
                state.jobs[current].h3AutomaticWorkflow?.status = "waiting";state.jobs[current].h3AutomaticWorkflow?.phase = "pixel_qa"
                state.jobs[current].stage = "等待队列恢复或前段接受 · 输入与冻结绑定保留";persist();return
            }
            startH3(id,approval:runtime.mode == .mock ? .mockForTests(binding.jobSHA256) : .userConfirmed(binding.jobSHA256),
                firstLaunchCheck:.init(binding:binding,completedAt:Date()))
            guard activeJob?.id == id else { throw StudioError.invalid(state.jobs[current].error ?? "首帧单镜未启动，已保存全部记录。") }
            state.jobs[current].h3AutomaticWorkflow?.phase = "video_generation";persist()
        } catch {
            abConfigurationBusy = false
            guard let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status.isPending else { return }
            state.jobs[current].status = .failed;state.jobs[current].stage = "首帧单镜启动失败 · 不自动重试"
            state.jobs[current].error = error.localizedDescription;state.jobs[current].endedAt = Date()
            state.jobs[current].h3AutomaticWorkflow?.status = "failed";state.jobs[current].h3AutomaticWorkflow?.endedAt = Date()
            state.jobs[current].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
            state.jobs[current].executionActivity?.finish(.failed,stage:state.jobs[current].stage,at:state.jobs[current].endedAt!)
            persist()
        }
    }
}
