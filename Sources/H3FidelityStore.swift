import Foundation

extension TaskStore {
    func canStartFidelity(_ id: UUID,kind: H3FidelityKind) -> Bool {
        guard singleGeneratorIdle,h3Runtime.mode == .real,
              let job = state.jobs.first(where:{ $0.id == id }),job.externalHistory == nil,job.supersededBy == nil,
              job.status == .completed,job.h3VideoRejection != nil,
              let proposal = job.h3Binding?.appFirstTask?.proposal,let input = proposal.input,
              proposal.reviewReady else { return false }
        // A completed or failed experiment with this input is not silently run
        // again. A changed input has its own immutable task/revision history.
        if job.h3FidelityChecks?.contains(where:{ $0.kind == kind && $0.originalSHA256 == input.originalSHA256 && $0.recipeVersion == H3Fidelity.recipeVersion }) == true { return false }
        if kind == .motionDetail {
            return job.h3FidelityChecks?.contains(where:{ $0.kind == .codecDetail && $0.status == "completed" && $0.recipeVersion == H3Fidelity.recipeVersion && $0.originalSHA256 == input.originalSHA256 }) == true
        }
        return true
    }
    func startFidelity(_ id: UUID,kind: H3FidelityKind) async {
        guard canStartFidelity(id,kind:kind),let index = state.jobs.firstIndex(where:{ $0.id == id }),let binding = state.jobs[index].h3Binding,
              let owner = ProcessIdentity.capture(getpid()) else { return }
        fidelityJobID = id;fidelityPreparing = true
        do {
            let executableHash = try await Task.detached(priority:.utility) { [executable] in try WorkspaceDigest.sha256(executable) }.value
            guard !shuttingDown,fidelityJobID == id else { throw StudioError.invalid("保真准备已取消。") }
            let request = H3FidelityRequest(id:UUID(),appJobID:id,workspace:root.path,owner:owner,sessionID:sessionID,kind:kind,binding:binding,appExecutableSHA256:executableHash)
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let bytes = try encoder.encode(request)
            _ = try H3Files.inside(request.directory,root.path + "/h3-fidelity")
            try FileManager.default.createDirectory(atPath:request.directory,withIntermediateDirectories:true)
            try bytes.write(to:request.url,options:.withoutOverwriting)
            let record = H3FidelityRecord(id:request.id,kind:kind,directory:request.directory,requestSHA256:H3ABConfigurationReader.digest(bytes),originalSHA256:binding.appFirstTask!.proposal.input!.originalSHA256)
            if state.jobs[index].h3FidelityChecks == nil { state.jobs[index].h3FidelityChecks = [] }
            state.jobs[index].h3FidelityChecks?.append(record)
            state.jobs[index].logTail.append("App 开始" + kind.title + "；保留原候选与拒绝，实验不计入视频分段，不授权续段。")
            persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
            let next = ProcessRunner();fidelityRunner = next
            try next.start(executable:executable,arguments:["--h3-fidelity-worker",request.url.path],directory:root,
                onLine:{ [weak self] line,stderr in self?.consumeFidelity(line,id:id,recordID:request.id) },
                onExit:{ [weak self] code in self?.finishFidelity(id:id,recordID:request.id,code:code) })
            if let r = state.jobs[index].h3FidelityChecks?.firstIndex(where:{ $0.id == request.id }) {
                state.jobs[index].h3FidelityChecks?[r].worker = ProcessIdentity.capture(next.process.processIdentifier)
                state.jobs[index].h3FidelityChecks?[r].status = "running"
            }
            fidelityPreparing = false;persist()
        } catch {
            if let r = state.jobs[index].h3FidelityChecks?.indices.last,state.jobs[index].h3FidelityChecks?[r].isActive == true {
                state.jobs[index].h3FidelityChecks?[r].status = "failed";state.jobs[index].h3FidelityChecks?[r].error = error.localizedDescription
                state.jobs[index].h3FidelityChecks?[r].endedAt = Date()
            }
            fidelityPreparing = false;fidelityJobID = nil;fidelityRunner = nil;notice = error.localizedDescription;persist()
        }
    }
    func consumeFidelity(_ line: String,id: UUID,recordID: UUID) {
        guard let data = line.data(using:.utf8),let event = try? JSONDecoder().decode(EngineEvent.self,from:data),
              let i = state.jobs.firstIndex(where:{ $0.id == id }),let j = state.jobs[i].h3FidelityChecks?.firstIndex(where:{ $0.id == recordID }) else { return }
        if let stage = event.stage { state.jobs[i].h3FidelityChecks?[j].stage = stage }
        if event.type == "progress",let count = event.completed,let total = event.total,total > 0,count >= 0,count <= total {
            state.jobs[i].h3FidelityChecks?[j].progress = .init(completed:count,total:total,unit:event.unit ?? "项")
        }
        if event.type == "error" { state.jobs[i].h3FidelityChecks?[j].error = event.message }
        if event.type == "owned" { fidelityOwnedProcesses = event.ownedProcesses ?? [] }
        // Native events drive redraws; the report and task identity stay stable.
        if event.type != "owned" { persist() }
    }
    func finishFidelity(id: UUID,recordID: UUID,code: Int32) {
        defer { fidelityRunner = nil;fidelityJobID = nil;fidelityPreparing = false;fidelityOwnedProcesses = [];persist() }
        guard let i = state.jobs.firstIndex(where:{ $0.id == id }),let j = state.jobs[i].h3FidelityChecks?.firstIndex(where:{ $0.id == recordID }),
              var record = state.jobs[i].h3FidelityChecks?[j] else { return }
        let cancelled = record.status == "cancelling" || code == 130
        record.status = cancelled ? "cancelled" : "failed";record.endedAt = Date()
        do {
            if code == 0 && !cancelled {
                let report = try H3Fidelity.validateReport(record,appJobID:id)
                record.reportSHA256 = H3ABConfigurationReader.digest(report);record.status = "completed"
                record.stage = "对照已完成 · 检查脸部和动作后再决定参数"
            }
        } catch { record.error = error.localizedDescription }
        if record.status == "failed" && record.error == nil { record.error = "保真监督器退出 \(code)，保留日志，不自动重试。" }
        state.jobs[i].h3FidelityChecks?[j] = record
        notice = record.status == "completed" ? record.kind.title + "已完成，原候选与拒绝记录保持，尚未接受新视频。" : (record.error ?? "保真对照已取消，记录保留。")
    }
    func cancelFidelity(_ id: UUID) {
        guard fidelityJobID == id else { return }
        if let i = state.jobs.firstIndex(where:{ $0.id == id }),let j = state.jobs[i].h3FidelityChecks?.indices.last,
           state.jobs[i].h3FidelityChecks?[j].isActive == true { state.jobs[i].h3FidelityChecks?[j].status = "cancelling";persist() }
        if fidelityPreparing { fidelityJobID = nil }
        fidelityRunner?.cancel()
    }
    func recordFidelityObservation(_ id: UUID,recordID: UUID,text: String,finding: H3FidelityFinding) throws {
        guard let i = state.jobs.firstIndex(where:{ $0.id == id }),let j = state.jobs[i].h3FidelityChecks?.firstIndex(where:{ $0.id == recordID }),
              let record = state.jobs[i].h3FidelityChecks?[j],record.status == "completed",record.observation == nil,
              (12...4000).contains(text.utf8.count),H3FidelityFinding.choices(for:record.kind).contains(finding),let reportHash = record.reportSHA256,
              try WorkspaceDigest.sha256(H3Files.inside(record.reportPath,record.directory)) == reportHash else { throw StudioError.invalid("对照结论缺少本次有效报告或已记录，未覆盖。") }
        let receipts = try H3Fidelity.outputReceipts(directory:record.directory,kind:record.kind)
        _ = try H3Fidelity.validateReport(record,appJobID:id)
        let guidance = H3FidelityGuidance.make(finding,shot:state.jobs[i].shot,kind:record.kind)
        let guidanceObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(guidance))
        let payload: [String:Any] = ["schema":"jingsheng-App-fidelity-observation-v1","appJobID":id.uuidString,"diagnosticID":recordID.uuidString,
            "reportSHA256":reportHash,"originalSHA256":record.originalSHA256,"frames":receipts,"observation":text,
            "finding":finding.rawValue,"guidance":guidanceObject,
            "source":"AppUI","actorKind":"unknown","videoAccepted":false,"continuationAuthorized":false,"recordedAt":ISO8601DateFormatter().string(from:Date())]
        let bytes = try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys])
        try bytes.write(to:URL(fileURLWithPath:record.directory + "/visual-observation.json"),options:.withoutOverwriting)
        state.jobs[i].h3FidelityChecks?[j].observation = text
        state.jobs[i].h3FidelityChecks?[j].finding = finding
        state.jobs[i].h3FidelityChecks?[j].guidance = guidance
        state.jobs[i].h3FidelityChecks?[j].observationSHA256 = H3ABConfigurationReader.digest(bytes);persist()
    }
}
