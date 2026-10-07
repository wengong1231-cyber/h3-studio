import Foundation

// A later user instruction can remove the numerical allowance without changing
// the original engine registration or any frozen experiment request.
struct H3ReferenceTrialPolicyInstruction: Codable, Equatable {
    var schema = "jingsheng-reference-trial-policy-v1"
    var appJobID: UUID
    var engineRegistrationSHA256: String
    var mode = "unlimited"
    var scope = "registered-engine-existing-models"
    var authorizationQuote: String
    var authorizationSource: String

    func validate(jobID: UUID,engine: H3ReferenceEngineBinding) throws {
        guard schema == "jingsheng-reference-trial-policy-v1",appJobID == jobID,
              engineRegistrationSHA256 == engine.receiptSHA256,mode == "unlimited",
              scope == "registered-engine-existing-models",
              (6...2000).contains(authorizationQuote.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count),
              (8...2000).contains(authorizationSource.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count) else {
            throw StudioError.invalid("次数设置须绑定当前任务、原引擎登记及明确用户指令；不会扩大模型或引擎范围。")
        }
        try engine.manifest.validateScope(jobID)
    }
}

struct H3ReferenceTrialPolicyReceipt: Codable, Equatable {
    var schema = "jingsheng-App-reference-trial-policy-receipt-v1"
    var instruction: H3ReferenceTrialPolicyInstruction
    var instructionSHA256: String
    var previousJobSHA256: String
    var priorTrialCount: Int
    var recordedAt: Date
    var source = "AppUI"
    var videoAccepted = false
    var newModelsDownloaded = false
}

struct H3ReferenceTrialPolicyBinding: Codable, Equatable {
    var instruction: H3ReferenceTrialPolicyInstruction
    var receiptPath: String
    var receiptSHA256: String

    func validate(jobID: UUID,engine: H3ReferenceEngineBinding,workspace: String) throws {
        try instruction.validate(jobID:jobID,engine:engine)
        let url = try H3Files.inside(receiptPath,workspace + "/h3-reference-engines/" + jobID.uuidString + "/trial-policies")
        let bytes = try H3Files.read(url)
        let receipt = try JSONDecoder().decode(H3ReferenceTrialPolicyReceipt.self,from:bytes)
        let directory = url.deletingLastPathComponent()
        let imported = try H3Files.read(H3Files.inside(directory.path + "/instruction.json",directory.path))
        let previous = try H3Files.read(H3Files.inside(directory.path + "/previous-job.json",directory.path))
        let previousJob = try JSONDecoder().decode(ShotJob.self,from:previous)
        guard H3ABConfigurationReader.digest(bytes) == receiptSHA256,
              receipt.schema == "jingsheng-App-reference-trial-policy-receipt-v1",receipt.instruction == instruction,
              receipt.source == "AppUI",!receipt.videoAccepted,!receipt.newModelsDownloaded,receipt.priorTrialCount >= 0,
              receipt.instructionSHA256 == H3ABConfigurationReader.digest(imported),
              try JSONDecoder().decode(H3ReferenceTrialPolicyInstruction.self,from:imported) == instruction,
              H3ABConfigurationReader.digest(previous) == receipt.previousJobSHA256,
              previousJob.id == jobID,previousJob.h3ReferenceEngine == engine,previousJob.h3ReferenceTrialPolicy == nil,
              receipt.priorTrialCount == H3ReferenceEngine.trialsUsed(in:previousJob) else {
            throw StudioError.invalid("次数设置的用户指令或历史审计已变化；未开始生成。")
        }
    }
}

extension H3ReferenceEngine {
    static func trialsUsed(in job: ShotJob) -> Int { (job.h3FidelityChecks ?? []).filter { $0.referenceEngine != nil }.count }

    static func hasUnlimitedTrials(_ job: ShotJob) -> Bool {
        guard let engine = job.h3ReferenceEngine,let policy = job.h3ReferenceTrialPolicy else { return false }
        return (try? policy.instruction.validate(jobID:job.id,engine:engine)) != nil
    }

    static func validateTrialAllowance(_ engine: H3ReferenceEngineBinding,job: ShotJob,workspace: String,
                                       policy: H3ReferenceTrialPolicyBinding?,includingCurrent: Bool) throws {
        guard job.h3ReferenceEngine == engine,policy == job.h3ReferenceTrialPolicy else {
            throw StudioError.invalid("隔离引擎或当前次数设置已变化。")
        }
        if let policy {
            try policy.validate(jobID:job.id,engine:engine,workspace:workspace)
        } else {
            let count = trialsUsed(in:job)
            guard includingCurrent ? count <= engine.manifest.maximumTrials : count < engine.manifest.maximumTrials else {
                throw StudioError.invalid("当前仍沿用历史次数设置；可通过应用登记新的用户指令。")
            }
        }
    }

    static func trialStatus(_ job: ShotJob) -> String {
        let used = trialsUsed(in:job)
        return hasUnlimitedTrials(job) ? "次数不限 · 已记录 \(used) 次试验" : "已用 \(used)/\(job.h3ReferenceEngine?.manifest.maximumTrials ?? 0) 次历史授权"
    }
}

extension TaskStore {
    func importReferenceTrialPolicy(_ url: URL,jobID: UUID) async throws {
        guard singleGeneratorIdle,h3Runtime.mode == .real,
              let index = state.jobs.firstIndex(where:{ $0.id == jobID }),
              state.jobs[index].status == .completed,state.jobs[index].supersededBy == nil,
              state.jobs[index].h3ReferenceTrialPolicy == nil,
              let engine = state.jobs[index].h3ReferenceEngine,
              let proposal = state.jobs[index].h3Binding?.appFirstTask?.proposal else {
            throw StudioError.invalid("需要空闲生成资源及尚未登记次数变更的原任务。")
        }
        let bytes = try H3Files.read(H3Files.safe(url.path))
        let instruction = try JSONDecoder().decode(H3ReferenceTrialPolicyInstruction.self,from:bytes)
        try instruction.validate(jobID:jobID,engine:engine)
        let original = state.jobs[index],workspacePath = root.path
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let previous = try encoder.encode(original)
        fidelityJobID = jobID;fidelityPreparing = true
        defer { fidelityJobID = nil;fidelityPreparing = false }
        try await Task.detached(priority:.utility) {
            try engine.validate(jobID:jobID,workspace:workspacePath,workDirectory:proposal.workDirectory)
        }.value
        guard !shuttingDown,fidelityJobID == jobID,
              let currentIndex = state.jobs.firstIndex(where:{ $0.id == jobID }),try encoder.encode(state.jobs[currentIndex]) == previous else {
            throw StudioError.invalid("任务在核对次数设置期间变化，未保存。")
        }
        let directory = try H3Files.inside(root.path + "/h3-reference-engines/" + jobID.uuidString + "/trial-policies/" + UUID().uuidString,root.path)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try previous.write(to:directory.appendingPathComponent("previous-job.json"),options:.withoutOverwriting)
        try bytes.write(to:directory.appendingPathComponent("instruction.json"),options:.withoutOverwriting)
        let receipt = H3ReferenceTrialPolicyReceipt(instruction:instruction,instructionSHA256:H3ABConfigurationReader.digest(bytes),
            previousJobSHA256:H3ABConfigurationReader.digest(previous),priorTrialCount:H3ReferenceEngine.trialsUsed(in:original),recordedAt:Date())
        let receiptBytes = try encoder.encode(receipt),receiptURL = directory.appendingPathComponent("receipt.json")
        try receiptBytes.write(to:receiptURL,options:.withoutOverwriting)
        let policy = H3ReferenceTrialPolicyBinding(instruction:instruction,receiptPath:receiptURL.path,receiptSHA256:H3ABConfigurationReader.digest(receiptBytes))
        try policy.validate(jobID:jobID,engine:engine,workspace:root.path)
        state.jobs[currentIndex].h3ReferenceTrialPolicy = policy
        state.jobs[currentIndex].logTail.append("按新的用户指令取消隔离试验次数限制；既有试验和原引擎登记保留，使用现有模型。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "试验次数限制已取消；历史完整保留，尚未启动新生成。"
    }
}
