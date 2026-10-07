import Foundation

extension TaskStore {
    func canImportInputReview(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }) else { return false }
        return job.status.isPending && job.supersededBy == nil && job.attempts.isEmpty && job.h3Binding == nil
            && job.h3FirstProposal?.input != nil && job.h3AutomaticWorkflow?.phase == "pixel_qa"
    }
    /// An App intake for an assistant's pixel inspection. Importing a review
    /// never supplies video acceptance, clears a pause, or relaxes fingerprints.
    func importInputReview(_ url: URL,id: UUID) async throws {
        guard canImportInputReview(id),let job = state.jobs.first(where:{ $0.id == id }),
              let proposal = job.h3FirstProposal else { throw StudioError.invalid("当前输入尚不可检查，或已进入投递；未修改图审。") }
        let destination = firstReviewURL(id),workspace = root
        abConfigurationBusy = true;configurationReadOperation = "核对并导入实际输入图审"
        do {
            let (data,review) = try await Task.detached(priority:.utility) {
                let data = try H3Files.read(H3Files.safe(url.path),limit:16384)
                let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
                let review = try decoder.decode(H3FirstPixelReview.self,from:data)
                var current = proposal;current.pixelReview = review
                guard review.appJobID == id,current.reviewBindingsMatch else { throw StudioError.invalid("图审不属于本任务的实际图片、提示词或修订。") }
                let input = proposal.input!
                guard try WorkspaceDigest.sha256(H3Files.safe(input.originalPath)) == input.originalSHA256,
                      try WorkspaceDigest.sha256(H3Files.safe(input.normalizedPath)) == input.normalizedSHA256,
                      try WorkspaceDigest.sha256(H3Files.safe(proposal.promptPath)) == proposal.promptSHA256 else {
                    throw StudioError.invalid("图审后的图片或提示词发生变化，未导入。")
                }
                for reference in proposal.queueExecution?.staticInput?.motionReferences ?? [] { _ = try reference.readVerified() }
                return (data,review)
            }.value
            guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].h3FirstProposal == proposal,
                  state.jobs[i].status.isPending,state.jobs[i].h3Binding == nil,state.jobs[i].attempts.isEmpty else {
                throw StudioError.invalid("任务已改变，未写入图审。")
            }
            _ = try H3Files.inside(destination.path,workspace.path + "/h3-config")
            let history = destination.deletingLastPathComponent().appendingPathComponent("input-review-history")
            try FileManager.default.createDirectory(at:history,withIntermediateDirectories:true)
            func archive(_ bytes: Data) throws {
                let path = history.appendingPathComponent(H3ABConfigurationReader.digest(bytes) + ".json")
                if FileManager.default.fileExists(atPath:path.path) {
                    guard try H3Files.read(path,limit:16384) == bytes else { throw StudioError.invalid("图审归档指纹不一致。") }
                } else { try bytes.write(to:path,options:.withoutOverwriting) }
            }
            if FileManager.default.fileExists(atPath:destination.path) { try archive(H3Files.read(destination,limit:16384)) }
            try archive(data);try data.write(to:destination,options:.atomic)
            state.jobs[i].logTail.append("App 导入输入图审：" + H3ABConfigurationReader.digest(data) + " · " + review.status + " · " + review.observation)
            persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            abConfigurationBusy = false
            await checkFirstPixelReviews()
        } catch { abConfigurationBusy = false;throw error }
    }
}
