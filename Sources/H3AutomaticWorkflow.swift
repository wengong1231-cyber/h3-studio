import Foundation

struct H3AutomaticWorkflow: Codable {
    var status: String
    var phase: String
    var startedAt: Date
    var endedAt: Date?
    var error: String?
    var automaticContinuationAuthorized: Bool?
}

extension TaskStore {
    func canStartS41Workflow(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where: { $0.id == id }),
              job.status.isPending,job.attempts.isEmpty,job.externalHistory == nil,
              let configuration = job.h3ABConfiguration,configuration.launchAuthorized else { return false }
        return job.h3InputPreparation?.status != "failed" && (job.h3Binding == nil || canRunH3(id))
    }

    /// Re-read the immutable snapshot and the actual images. Legacy operator
    /// flags are kept as history, and never invented or used as a launch gate.
    func validateS41Inputs(_ id: UUID) async throws {
        guard canUseS41Resources(id),let index = state.jobs.firstIndex(where: { $0.id == id }),
              state.jobs[index].status.isPending,let configuration = state.jobs[index].h3ABConfiguration,
              let snapshot = configuration.snapshotPath else { throw StudioError.invalid("自动输入检查无法开始；任务或资源状态已变化。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        _ = try H3Files.inside(snapshot,root.path + "/h3-config")
        let started = Date(),mock = h3Runtime.mode == .mock
        if state.jobs[index].h3InputPreparation == nil { state.jobs[index].h3InputPreparation = .init(materialsStartedAt:started,materialsEndedAt:started) }
        state.jobs[index].h3InputPreparation?.automaticValidationStatus = "running"
        state.jobs[index].h3InputPreparation?.automaticValidationStartedAt = started
        state.jobs[index].h3InputPreparation?.automaticValidationEndedAt = nil
        state.jobs[index].stage = "自动输入检查 · 完整解码、尺寸与指纹"
        state.jobs[index].executionActivity?.milestone(state.jobs[index].stage,at:started,phase:.preparing)
        state.jobs[index].h3AutomaticWorkflow?.phase = "input_validation"
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        do {
            var checked = try await Task.detached(priority:.utility) {
                let data = try H3Files.read(URL(fileURLWithPath:snapshot),limit:1_048_576)
                guard H3ABConfigurationReader.digest(data) == configuration.sourceSHA256 else { throw StudioError.invalid("S41 配置快照指纹变化，自动检查未通过。") }
                let read = try H3ABConfigurationReader.parse(data,sourcePath:configuration.sourcePath,workDirectory:configuration.workDirectory,mock:mock)
                guard read.configuration.blockers.isEmpty,read.configuration.automaticInputsValidated else {
                    throw StudioError.invalid(read.configuration.blockers.first ?? "A/B 自动输入检查未通过。")
                }
                return read.configuration
            }.value
            guard !shuttingDown,let current = state.jobs.firstIndex(where: { $0.id == id }),state.jobs[current].status.isPending,
                  state.jobs[current].h3ABConfiguration == configuration else { throw H3PreprocessingCancelled() }
            checked.snapshotPath = snapshot;checked.revision = configuration.revision
            struct Receipt: Codable {
                var schema = "jingsheng-automatic-input-check-v1"
                var appJobID: UUID
                var startedAt: Date
                var endedAt: Date
                var configurationSHA256: String
                var first: H3ImageTechnicalCheck
                var last: H3ImageTechnicalCheck
                var operatorApprovalRequired = false
                var semanticQualityAssessed = false
            }
            let ended = Date(),directory = root.appendingPathComponent("h3-config/" + id.uuidString)
            let receipt = directory.appendingPathComponent("automatic-input-check-" + UUID().uuidString + ".json")
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Receipt(appJobID:id,startedAt:started,endedAt:ended,configurationSHA256:checked.sourceSHA256,first:checked.first.automaticCheck!,last:checked.last.automaticCheck!)).write(to:receipt,options:.withoutOverwriting)
            state.jobs[current].h3ABConfiguration = checked
            state.jobs[current].h3InputPreparation?.automaticValidationStatus = "completed"
            state.jobs[current].h3InputPreparation?.automaticValidationEndedAt = ended
            state.jobs[current].h3InputPreparation?.automaticValidationReceiptPath = receipt.path
            state.jobs[current].stage = "A/B 自动输入检查通过"
            state.jobs[current].executionActivity?.milestone(state.jobs[current].stage,at:ended,phase:.preparing)
            state.jobs[current].logTail.append("A/B 完整解码、768×448、SHA-256、独立首末图与端口配置自动检查通过；没有要求操作员确认，未声称语义画质通过。")
            persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        } catch {
            if let current = state.jobs.firstIndex(where: { $0.id == id }) {
                state.jobs[current].h3InputPreparation?.automaticValidationStatus = state.jobs[current].status == .cancelled ? "cancelled" : "failed"
                state.jobs[current].h3InputPreparation?.automaticValidationEndedAt = Date();persist()
            }
            throw error
        }
    }

    func startAuthorizedS41(_ id: UUID) async {
        guard canStartS41Workflow(id),let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
        abWorkflowID = id;defer { abWorkflowID = nil }
        state.jobs[index].h3AutomaticWorkflow = .init(status:"running",phase:"input_preparation",startedAt:Date())
        state.jobs[index].stage = "自动生成流程 · 准备输入";state.jobs[index].error = nil
        state.jobs[index].executionActivity = .init(stage:state.jobs[index].stage,at:state.jobs[index].h3AutomaticWorkflow!.startedAt)
        persist()
        do {
            guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            if state.jobs[index].h3ABConfiguration?.first.normalizedSHA256 == nil || state.jobs[index].h3ABConfiguration?.last.normalizedSHA256 == nil {
                await prepareS41Inputs(id)
            }
            guard !shuttingDown,let current = state.jobs.firstIndex(where: { $0.id == id }),state.jobs[current].status.isPending else { return }
            if let error = state.jobs[current].h3InputPreparation?.error { throw StudioError.invalid(error) }
            try await validateS41Inputs(id)
            guard !shuttingDown,state.jobs.first(where: { $0.id == id })?.status.isPending == true else { return }
            let binding: H3Binding
            if let existing = state.jobs.first(where: { $0.id == id })?.h3Binding { _ = try existing.revalidate();binding = existing }
            else { binding = try await materializeS41(id) }
            guard binding.appABTask?.configuration.launchAuthorized == true else { throw StudioError.invalid("本条任务没有生成授权，未启动。") }
            startH3(id,approval:h3Runtime.mode == .mock ? .mockForTests(binding.jobSHA256) : .userConfirmed(binding.jobSHA256))
            guard activeJob?.id == id else { throw StudioError.invalid(state.jobs.first(where: { $0.id == id })?.error ?? notice ?? "单镜未启动；已保留输入与检查记录。") }
            if let current = state.jobs.firstIndex(where: { $0.id == id }) { state.jobs[current].h3AutomaticWorkflow?.phase = "video_generation";persist() }
        } catch {
            guard let current = state.jobs.firstIndex(where: { $0.id == id }) else { return }
            if state.jobs[current].status.isPending { state.jobs[current].status = .failed;state.jobs[current].stage = "自动流程失败 · 未进入 GPU";state.jobs[current].error = error.localizedDescription }
            state.jobs[current].h3AutomaticWorkflow?.status = state.jobs[current].status == .cancelled ? "cancelled" : "failed"
            state.jobs[current].h3AutomaticWorkflow?.endedAt = Date();state.jobs[current].h3AutomaticWorkflow?.error = error.localizedDescription
            if state.jobs[current].status == .failed {
                state.jobs[current].endedAt = state.jobs[current].h3AutomaticWorkflow?.endedAt
                state.jobs[current].executionActivity?.finish(.failed,stage:state.jobs[current].stage,at:state.jobs[current].endedAt!)
            }
            notice = error.localizedDescription;persist()
        }
    }
}
