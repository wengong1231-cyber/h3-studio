import Foundation

extension TaskStore {
    func canReviseAction(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.status == .failed,
              job.engine == .h3,job.externalHistory == nil,job.attempts.isEmpty,job.h3Binding == nil,
              job.h3QueuePlan != nil,job.h3FirstProposal?.input != nil,job.h3FirstProposal?.queueExecution != nil,
              job.h3FirstProposal?.launchAuthorized == true else { return false }
        return true
    }
    /// Stages immutable files before switching the same persisted task. Neither
    /// a failed import nor cancellation modifies the previous failed record.
    func reviseAction(_ id: UUID,requestURL: URL = H3ActionRevision.knownRequest) async {
        guard canReviseAction(id),let index = state.jobs.firstIndex(where:{ $0.id == id }) else { return }
        let original = state.jobs[index],workspace = root,runtime = h3Runtime,reviewURL = firstReviewURL(id)
        let control = H3PreparationControl();actionRevisionID = id;actionRevisionControl = control
        configurationReadOperation = "核对 \(original.shortID) 动作修订与原失败记录"
        abConfigurationBusy = true
        do {
            let proposal = try await Task.detached(priority:.utility) {
                try H3ActionRevision.prepare(job:original,requestURL:requestURL,reviewURL:reviewURL,workspace:workspace,runtime:runtime,control:control)
            }.value
            try control.check()
            guard !shuttingDown,let current = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[current].status == .failed,
                  state.jobs[current].h3FirstProposal == original.h3FirstProposal,state.jobs[current].attempts.isEmpty,state.jobs[current].h3Binding == nil else {
                throw StudioError.invalid("任务状态变化；动作修订已暂存，未接续。")
            }
            state.jobs[current].h3FirstProposal = proposal;state.jobs[current].prompt = proposal.prompt
            if let revision = proposal.queueExecution?.actionRevision {
                state.jobs[current].resultRevisionLinks = original.effectiveResultRevisionLinks + [
                    .init(fromRevision:original.actionRevisionNumber,toRevision:revision.number,
                        previousStateSHA256:revision.previousStateSHA256,promptSHA256:revision.promptSHA256)
                ]
            }
            state.jobs[current].h3AutomaticWorkflow = nil;state.jobs[current].h3InputPreparation = .init(materialsStartedAt:Date(),materialsEndedAt:Date())
            state.jobs[current].executionActivity = nil;state.jobs[current].progress = nil;state.jobs[current].startedAt = nil;state.jobs[current].endedAt = nil
            state.jobs[current].status = .blocked;state.jobs[current].error = nil;state.jobs[current].updatedAt = Date()
            state.jobs[current].stage = "动作已修订 · 自动重新准备实际源帧"
            state.jobs[current].logTail.append("动作修订 r\(proposal.queueExecution!.actionRevision!.number)：同一任务身份与原清单参数保留。旧失败、提示词、提案和QA已冻结；旧QA不能启动新任务。")
            persist()
            guard storageFault == nil else { state.jobs[current] = original;throw StudioError.invalid(storageFault!) }
            abConfigurationBusy = false;actionRevisionID = nil;actionRevisionControl = nil
            await startAuthorizedFirst(id)
        } catch {
            abConfigurationBusy = false;actionRevisionID = nil;actionRevisionControl = nil
            notice = error is H3PreprocessingCancelled ? "已取消动作修订，原失败记录保留。" : error.localizedDescription
        }
    }
}
