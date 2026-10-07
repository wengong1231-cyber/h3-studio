import Foundation

struct H3VideoCandidateIdentity: Codable, Equatable {
    var appJobID: UUID
    var requestID: String
    var nativeJobSHA256: String
    var clipSHA256: String
    var reportSHA256: String?
    var actionRevision: Int?
    var promptSHA256: String
    var staticBindingSHA256: String?
}
struct H3VideoRejectionRecord: Codable, Equatable {
    var schema = "jingsheng-App-video-rejection-v1"
    var candidate: H3VideoCandidateIdentity
    var reason: String
    var origin: String
    var actorKind: String
    var sourceReference: String
    var recordedAt: Date
    var instructionPath: String?
    var instructionSHA256: String?
    var previousAcceptanceReceiptSHA256: String?
}
struct H3VideoRejectionState: Codable, Equatable {
    var receiptPath: String
    var receiptSHA256: String
    var record: H3VideoRejectionRecord
    var actorKind: String { record.actorKind }
    var reason: String { record.reason }
    var sourceReference: String { record.sourceReference }
}
struct H3UserVideoRejectionInstruction: Codable {
    var schema = "jingsheng-App-user-video-rejection-instruction-v1"
    var candidate: H3VideoCandidateIdentity
    var actorKind: String
    var explicitUserRejection: Bool
    var sourceReference: String
    var reason: String
    var rejectedAt: Date
}

enum H3VideoRejectionReader {
    static func url(workspace: URL,id: UUID) -> URL {
        workspace.appendingPathComponent("h3-queue-reviews/" + id.uuidString + "/rejection.json")
    }
    static func identity(job: ShotJob,workspace: URL,runtime: H3Runtime) throws -> H3VideoCandidateIdentity {
        guard job.supersededBy == nil,job.externalHistory == nil,
              [.completed,.failed,.cancelled,.interrupted].contains(job.status),
              let plan = job.h3QueuePlan,let binding = job.h3Binding,binding.appTaskID == job.id else {
            throw StudioError.invalid("当前任务还没有可绑定的原生候选。")
        }
        let (_,loaded) = try H3FirstTaskBinding.load(H3Files.safe(binding.jobPath),runtime:runtime,requireFresh:false,allowHistoricalAcceptance:true)
        guard loaded.app_first_task?.appJobID == job.id,loaded.app_first_task?.appWorkspace == workspace.path,
              try WorkspaceDigest.sha256(H3Files.safe(binding.jobPath)) == binding.jobSHA256 else { throw StudioError.invalid("候选执行身份已经变化。") }
        let clip = try H3Files.inside(binding.clipPath,binding.outputDirectory)
        let clipHash = try WorkspaceDigest.sha256(clip)
        var reportHash: String?
        if let path = job.h3Outcome?.reportPath {
            guard path == binding.outputDirectory + "/technical-validation.json" else { throw StudioError.invalid("候选技术回执不属于本次输出目录。") }
            reportHash = try WorkspaceDigest.sha256(H3Files.safe(path))
        }
        let proposal = loaded.app_first_task!.proposal
        return .init(appJobID:job.id,requestID:plan.requestID,nativeJobSHA256:binding.jobSHA256,clipSHA256:clipHash,
            reportSHA256:reportHash,actionRevision:proposal.queueExecution?.actionRevision?.number,
            promptSHA256:proposal.promptSHA256,staticBindingSHA256:proposal.queueExecution?.staticInput?.recordSHA256)
    }
    static func read(workspace: URL,id: UUID) throws -> H3VideoRejectionState? {
        let path = url(workspace:workspace,id:id)
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        let bytes = try H3Files.read(H3Files.inside(path.path,workspace.path + "/h3-queue-reviews"),limit:32768)
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(H3VideoRejectionRecord.self,from:bytes)
        guard record.schema == "jingsheng-App-video-rejection-v1",record.candidate.appJobID == id,
              (8...4000).contains(record.reason.utf8.count),(8...2000).contains(record.sourceReference.utf8.count),
              ["unknown","user"].contains(record.actorKind),["app_ui","external_user_instruction"].contains(record.origin),
              ModelStatusReader.isHash(record.candidate.nativeJobSHA256,length:64),ModelStatusReader.isHash(record.candidate.clipSHA256,length:64) else {
            throw StudioError.invalid("候选拒绝记录不完整，续段保持阻塞。")
        }
        if record.origin == "external_user_instruction" {
            guard record.actorKind == "user",let source = record.instructionPath,let hash = record.instructionSHA256 else {
                throw StudioError.invalid("用户拒绝缺少冻结来源。")
            }
            let input = try H3Files.read(H3Files.inside(source,workspace.path + "/h3-queue-reviews/" + id.uuidString + "/rejection-instructions"),limit:32768)
            guard H3ABConfigurationReader.digest(input) == hash else { throw StudioError.invalid("用户拒绝来源指纹已变化。") }
            let instruction = try parseInstruction(input,identity:record.candidate)
            guard instruction.reason == record.reason,instruction.sourceReference == record.sourceReference else { throw StudioError.invalid("拒绝内容与实际来源不同。") }
        } else if record.actorKind != "unknown" { throw StudioError.invalid("界面操作不能认定为用户拒绝。") }
        return .init(receiptPath:path.path,receiptSHA256:H3ABConfigurationReader.digest(bytes),record:record)
    }
    static func blocksContinuation(workspace: URL,id: UUID,nativeSHA256: String,clipSHA256: String) throws -> Bool {
        guard let state = try read(workspace:workspace,id:id) else { return false }
        guard state.record.candidate.nativeJobSHA256 == nativeSHA256,state.record.candidate.clipSHA256 == clipSHA256 else {
            throw StudioError.invalid("拒绝记录与前段当前输出不一致，需核对后才能接续。")
        }
        return true
    }
    static func parseInstruction(_ bytes: Data,identity: H3VideoCandidateIdentity) throws -> H3UserVideoRejectionInstruction {
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw StudioError.invalid("需要明确的用户拒绝来源。") }
        let instruction: H3UserVideoRejectionInstruction
        if object["schema"] as? String == "S35p01-r2-user-rejection-v1" {
            // A supported existing parent handoff explicitly carries the user
            // quote, source message, revision and output hash. No UI actor inferred.
            guard identity.actionRevision == 2,object["appJobID"] as? String == identity.appJobID.uuidString,
                  object["actionRevision"] as? Int == 2,object["outputSHA256"] as? String == identity.clipSHA256,
                  (object["decision"] as? String)?.hasPrefix("rejected_by_user") == true,
                  let quote = object["exactUserQuote"] as? String,let reply = object["userReplyID"] as? String,
                  let thread = object["sourceThreadID"] as? String,let date = object["recordedAtUTC"] as? String else {
                throw StudioError.invalid("现有拒绝交接不属于当前 r2 候选。")
            }
            let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            guard let recorded = formatter.date(from:date) ?? ISO8601DateFormatter().date(from:date) else { throw StudioError.invalid("拒绝来源时间无效。") }
            instruction = .init(candidate:identity,actorKind:"user",explicitUserRejection:true,sourceReference:"thread:" + thread + "/message:" + reply,reason:quote,rejectedAt:recorded)
        } else {
            let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            instruction = try decoder.decode(H3UserVideoRejectionInstruction.self,from:bytes)
        }
        guard instruction.schema == "jingsheng-App-user-video-rejection-instruction-v1",instruction.candidate == identity,
              instruction.actorKind == "user",instruction.explicitUserRejection,
              (8...4000).contains(instruction.reason.utf8.count),(8...2000).contains(instruction.sourceReference.utf8.count),
              !instruction.sourceReference.hasPrefix("AppUI_") else { throw StudioError.invalid("用户拒绝必须绑定实际候选与明确来源，界面点击不能冒认为用户。") }
        return instruction
    }
    static func record(job: ShotJob,workspace: URL,runtime: H3Runtime,reason: String,source: URL? = nil) throws -> H3VideoRejectionState {
        let identity = try identity(job:job,workspace:workspace,runtime:runtime)
        var record = H3VideoRejectionRecord(candidate:identity,reason:reason,origin:"app_ui",actorKind:"unknown",
            sourceReference:"AppUI_reject:" + UUID().uuidString,recordedAt:Date())
        if let source {
            let bytes = try H3Files.read(H3Files.safe(source.path),limit:32768),instruction = try parseInstruction(bytes,identity:identity)
            let hash = H3ABConfigurationReader.digest(bytes),path = workspace.appendingPathComponent("h3-queue-reviews/" + job.id.uuidString + "/rejection-instructions/" + hash + "/source.json")
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try H3ActionRevision.writeImmutable(bytes,to:path.path)
            record.reason = instruction.reason;record.origin = "external_user_instruction";record.actorKind = instruction.actorKind
            record.sourceReference = instruction.sourceReference;record.recordedAt = instruction.rejectedAt
            record.instructionPath = path.path;record.instructionSHA256 = hash
        }
        guard (8...4000).contains(record.reason.utf8.count) else { throw StudioError.invalid("请填写具体拒绝原因。") }
        if let previous = try read(workspace:workspace,id:job.id) {
            guard previous.record.candidate == identity else { throw StudioError.invalid("原拒绝属于其他输出，没有覆盖。") }
            if source == nil || previous.record.instructionSHA256 == record.instructionSHA256 { return previous }
        }
        let acceptance = H3QueueExecution.reviewURL(workspace:workspace,id:job.id)
        if FileManager.default.fileExists(atPath:acceptance.path) { record.previousAcceptanceReceiptSHA256 = try WorkspaceDigest.sha256(acceptance) }
        let target = url(workspace:workspace,id:job.id)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:target.path) {
            let bytes = try H3Files.read(target,limit:32768),history = target.deletingLastPathComponent().appendingPathComponent("rejection-history/" + H3ABConfigurationReader.digest(bytes) + ".json")
            try FileManager.default.createDirectory(at:history.deletingLastPathComponent(),withIntermediateDirectories:true)
            try H3ActionRevision.writeImmutable(bytes,to:history.path)
        }
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(record).write(to:target,options:.atomic)
        return try read(workspace:workspace,id:job.id)!
    }
}

extension ShotJob {
    var videoContinuationAuthorized: Bool { h3VideoRejection == nil && h3VideoReview?.canAuthorizeContinuation == true }
}
extension TaskStore {
    func canRejectVideo(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,let job = state.jobs.first(where:{ $0.id == id }),job.supersededBy == nil,job.externalHistory == nil,
              [.completed,.failed,.cancelled,.interrupted].contains(job.status),job.h3QueuePlan != nil,let binding = job.h3Binding,binding.appTaskID == id else { return false }
        return FileManager.default.fileExists(atPath:binding.clipPath)
    }
    func rejectVideo(_ id: UUID,reason: String,source: URL? = nil) async throws {
        guard canRejectVideo(id),let job = state.jobs.first(where:{ $0.id == id }) else { throw StudioError.invalid("当前还没有可拒绝的候选，或现有任务正在运行。") }
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        configurationReadOperation = "记录 " + job.shortID + " 候选拒绝与精确输出身份"
        let workspace = root,runtime = h3Runtime
        let rejection = try await Task.detached(priority:.utility) { try H3VideoRejectionReader.record(job:job,workspace:workspace,runtime:runtime,reason:reason,source:source) }.value
        guard !shuttingDown,let i = state.jobs.firstIndex(where:{ $0.id == id }),state.jobs[i].h3Binding == job.h3Binding,state.jobs[i].supersededBy == nil else { throw StudioError.invalid("任务身份已变化，拒绝已暂存但没有接续。") }
        let before = state
        state.jobs[i].h3VideoRejection = rejection;state.jobs[i].stage = "候选已拒绝 · 已保留原视频与技术记录"
        state.jobs[i].logTail.append("候选拒绝：" + rejection.reason + "；操作者来源 " + rejection.actorKind + "；" + rejection.sourceReference)
        for j in state.jobs.indices where state.jobs[j].supersededBy == nil && state.jobs[j].h3QueuePlan?.shot == job.shot &&
            (state.jobs[j].h3QueuePlan?.part ?? 0) > job.h3QueuePlan!.part && state.jobs[j].status.isPending {
            state.jobs[j].h3AutomaticWorkflow?.automaticContinuationAuthorized = false
            state.jobs[j].stage = "前段候选已拒绝 · 旧端点与旧QA不能接续"
            state.jobs[j].progress = nil
        }
        persist();guard storageFault == nil else { state = before;throw StudioError.invalid(storageFault!) }
        notice = "拒绝已记录，候选与原验收保留；没有启动重做或下一段。"
    }
}
