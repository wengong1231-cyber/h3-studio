import Foundation

/// Historical whole-candidate acceptance is distinct from a queue endpoint review.
/// It cannot authorize a continuation, an editorial selection, or a new generation.
struct H3ABAcceptedCandidate: Codable, Equatable {
    var appJobID: UUID
    var nativeJobSHA256: String
    var configurationSHA256: String
    var clipSHA256: String
    var reportSHA256: String
}

struct H3ABAcceptanceInstruction: Codable, Equatable {
    var schema = "jingsheng-App-AB-existing-user-acceptance-v1"
    var candidate: H3ABAcceptedCandidate
    var actorKind: String
    var explicitUserAcceptance: Bool
    var sourceReference: String
    var userQuote: String
    var scope = "existing_ab_candidate_only"

    func validate(_ expected: H3ABAcceptedCandidate) throws {
        guard schema == "jingsheng-App-AB-existing-user-acceptance-v1",candidate == expected,
              actorKind == "user",explicitUserAcceptance,scope == "existing_ab_candidate_only",
              (8...2000).contains(sourceReference.utf8.count),!sourceReference.hasPrefix("AppUI_"),
              (6...4000).contains(userQuote.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count) else {
            throw StudioError.invalid("既有接受指令缺少明确用户原话、来源，或与本次 A/B 候选身份不符。")
        }
    }
}

struct H3ABAcceptanceReceipt: Codable, Equatable {
    var schema = "jingsheng-App-AB-existing-user-acceptance-receipt-v1"
    var instruction: H3ABAcceptanceInstruction
    var instructionPath: String
    var instructionSHA256: String
    var previousJobPath: String
    var previousJobSHA256: String
    var recordedAt: Date
}

struct H3ABAcceptanceState: Codable, Equatable {
    var receiptPath: String
    var receiptSHA256: String
    var receipt: H3ABAcceptanceReceipt
}

enum H3ABAcceptanceReader {
    static func directory(_ workspace: URL,_ id: UUID) throws -> URL {
        try H3Files.inside(workspace.path + "/h3-ab-acceptance/" + id.uuidString,workspace.path)
    }
    static func eligible(_ job: ShotJob) -> Bool {
        job.engine == .h3 && job.status == .completed && job.supersededBy == nil && job.externalHistory == nil
            && job.h3QueuePlan == nil && job.h3FirstProposal == nil && job.h3VideoReview == nil
            && job.h3VideoRejection == nil && job.cancellationSource == nil
            && job.h3Binding?.appABTask?.appJobID == job.id && job.h3Outcome?.technicalPass == true
            && job.h3Outcome?.selectedForProduction == false
            && ["pending","not_automatically_evaluated","accepted_existing_user_instruction"].contains(job.h3Outcome?.visualReview ?? "")
    }
    static func identity(job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3ABAcceptedCandidate {
        guard eligible(job),let binding = job.h3Binding,let ab = binding.appABTask,let outcome = job.h3Outcome,
              ab.appWorkspace == workspace.path,job.h3ABConfiguration == ab.configuration,
              job.candidate == binding.clipPath,outcome.reportPath == binding.outputDirectory + "/technical-validation.json",
              !FileManager.default.fileExists(atPath:H3VideoRejectionReader.url(workspace:workspace,id:job.id).path) else {
            throw StudioError.invalid("当前任务不是可补记接受来源的完整 A/B 候选，或已有拒绝、取消及重做记录。")
        }
        let (verified,_) = try H3ABTaskBinding.load(H3Files.safe(binding.jobPath),runtime:runtime,requireFresh:false,allowHistoricalInputChecks:true)
        guard verified == binding,outcome.simulated == (runtime.mode == .mock) else { throw StudioError.invalid("A/B 原生任务与 App 保存的身份不一致。") }
        let clip = try H3Files.inside(binding.clipPath,binding.outputDirectory)
        let clipHash = try WorkspaceDigest.sha256(clip)
        let reportData = try H3Files.read(H3Files.inside(outcome.reportPath,binding.outputDirectory),limit:1_048_576)
        guard let report = try JSONSerialization.jsonObject(with:reportData) as? [String:Any],
              ((report["schema"] as? String == "jingsheng-App-S41-native-technical-v1" && report["status"] as? String == "technical_pass_visual_review_pending")
               || (report["schema"] as? String == "jingsheng-App-S41-native-technical-v2" && report["status"] as? String == "technical_pass")),
              report["app_job_id"] as? String == job.id.uuidString,report["job_id"] as? String == binding.nativeJobID,
              report["clip_path"] as? String == clip.path,report["clip_sha256"] as? String == clipHash,
              report["decoded_video_frames"] as? Int == 73,report["native_lossless_frames"] as? Int == 73,
              report["dimensions"] as? [Int] == [768,448],report["fps"] as? Int == 24,
              report["B_anchor_index"] as? Int == 72,report["native_exit_code"] as? Int == 0,
              report["strict_full_av_decode"] as? String == "pass",report["strict_lossless_decode"] as? String == "pass",
              report["original_frozen_files_unchanged"] as? Bool == true,
              report["adaptation_executed"] as? Bool == false,report["selected_for_production"] as? Bool == false,
              report["simulated"] as? Bool == outcome.simulated,
              report["native73_runtime_observed"] as? Bool == !outcome.simulated else {
            throw StudioError.invalid("A/B 视频与原技术报告的身份或技术通过结果不一致。")
        }
        return .init(appJobID:job.id,nativeJobSHA256:binding.jobSHA256,configurationSHA256:ab.configurationSHA256,
                     clipSHA256:clipHash,reportSHA256:H3ABConfigurationReader.digest(reportData))
    }
    static func load(job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3ABAcceptanceState {
        let candidate = try identity(job:job,workspace:workspace,runtime:runtime)
        let folder = try directory(workspace,job.id),url = folder.appendingPathComponent("acceptance.json")
        let data = try H3Files.read(url,limit:32_768),receipt = try JSONDecoder().decode(H3ABAcceptanceReceipt.self,from:data)
        try receipt.instruction.validate(candidate)
        guard receipt.schema == "jingsheng-App-AB-existing-user-acceptance-receipt-v1",
              receipt.instructionPath == folder.appendingPathComponent("instruction.json").path,
              receipt.previousJobPath == folder.appendingPathComponent("previous-job.json").path,
              receipt.recordedAt.timeIntervalSince1970 > 0 else { throw StudioError.invalid("A/B 接受回执路径或版本无效。") }
        let instructionData = try H3Files.read(H3Files.inside(receipt.instructionPath,folder.path),limit:16_384)
        let previousData = try H3Files.read(H3Files.inside(receipt.previousJobPath,folder.path),limit:4_194_304)
        let previous = try JSONDecoder().decode(ShotJob.self,from:previousData)
        guard H3ABConfigurationReader.digest(instructionData) == receipt.instructionSHA256,
              try JSONDecoder().decode(H3ABAcceptanceInstruction.self,from:instructionData) == receipt.instruction,
              H3ABConfigurationReader.digest(previousData) == receipt.previousJobSHA256,
              previous.h3ABAcceptance == nil,previous.h3Outcome?.visualReview != "accepted_existing_user_instruction",
              try identity(job:previous,workspace:workspace,runtime:runtime) == candidate else {
            throw StudioError.invalid("既有接受原话或补记前的任务审计与当前候选不一致。")
        }
        return .init(receiptPath:url.path,receiptSHA256:H3ABConfigurationReader.digest(data),receipt:receipt)
    }
    static func importInstruction(_ url: URL,job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3ABAcceptanceState {
        let candidate = try identity(job:job,workspace:workspace,runtime:runtime)
        let data = try H3Files.read(H3Files.safe(url.path),limit:16_384)
        let instruction = try JSONDecoder().decode(H3ABAcceptanceInstruction.self,from:data)
        try instruction.validate(candidate)
        let folder = try directory(workspace,job.id),receiptURL = folder.appendingPathComponent("acceptance.json")
        let fm = FileManager.default
        if fm.fileExists(atPath:receiptURL.path) {
            let existing = try load(job:job,workspace:workspace,runtime:runtime)
            guard existing.receipt.instruction == instruction else { throw StudioError.invalid("此候选已有不同的接受来源；保留原回执，不能覆盖。") }
            return existing
        }
        guard job.h3ABAcceptance == nil,job.h3Outcome?.visualReview != "accepted_existing_user_instruction" else {
            throw StudioError.invalid("已登记接受但原回执缺失；请恢复原审计文件，不能重新创建来源。")
        }
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let previous = try encoder.encode(job)
        let instructionURL = folder.appendingPathComponent("instruction.json"),previousURL = folder.appendingPathComponent("previous-job.json")
        // Resume an interrupted write only when its immutable artifacts still match.
        for (target,bytes) in [(instructionURL,data),(previousURL,previous)] {
            if fm.fileExists(atPath:target.path) {
                guard try H3Files.read(target,limit:4_194_304) == bytes else { throw StudioError.invalid("未完成的接受补记已有不同审计内容；保留现场，不能覆盖。") }
            } else { try bytes.write(to:target,options:.withoutOverwriting) }
        }
        let receipt = H3ABAcceptanceReceipt(instruction:instruction,instructionPath:instructionURL.path,
            instructionSHA256:H3ABConfigurationReader.digest(data),previousJobPath:previousURL.path,
            previousJobSHA256:H3ABConfigurationReader.digest(previous),recordedAt:Date())
        try encoder.encode(receipt).write(to:receiptURL,options:.withoutOverwriting)
        return try load(job:job,workspace:workspace,runtime:runtime)
    }
}

extension TaskStore {
    func canImportABAcceptance(_ id: UUID) -> Bool {
        candidateReviewResourcesAvailable && fidelityJobID != id && abWorkflowID != id
            && state.jobs.first(where:{ $0.id == id }).map(H3ABAcceptanceReader.eligible) == true
    }
    func importABAcceptance(_ url: URL,id: UUID) async throws {
        guard canImportABAcceptance(id),let job = state.jobs.first(where:{ $0.id == id }) else { throw StudioError.invalid("当前 A/B 任务不能补记既有接受。") }
        abConfigurationBusy = true;configurationReadOperation = "核对 A/B 原候选、技术报告与既有用户接受原话"
        defer { abConfigurationBusy = false }
        let workspace = root,runtime = h3Runtime
        let accepted = try await Task.detached(priority:.utility) {
            try H3ABAcceptanceReader.importInstruction(url,job:job,workspace:workspace,runtime:runtime)
        }.value
        guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),H3ABAcceptanceReader.eligible(state.jobs[i]),
              state.jobs[i].h3Binding == job.h3Binding,state.jobs[i].candidate == job.candidate else {
            throw StudioError.invalid("补记时任务状态已变化；原审计保留，未修改接受状态。")
        }
        if state.jobs[i].h3ABAcceptance != accepted || state.jobs[i].h3Outcome?.visualReview != "accepted_existing_user_instruction" {
            state.jobs[i].h3ABAcceptance = accepted;state.jobs[i].h3Outcome?.visualReview = "accepted_existing_user_instruction"
            state.jobs[i].updatedAt = Date()
            state.jobs[i].logTail.append("已补记既有用户接受；原话、视频与技术报告指纹及补记前任务留档。仅此 A/B 候选，不创建续段或成片导出。回执 " + accepted.receiptSHA256)
            persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        }
        notice = "既有用户接受已补记到原 A/B 任务；原视频和补记前记录保留，未生成、裁剪或选入成片。"
    }
}
