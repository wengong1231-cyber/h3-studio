import Foundation

@MainActor enum H3ReferenceTrialPolicySelfTests {
    static func run(root: URL,engine: H3ReferenceEngineBinding,check: (String,Bool,String) throws -> Void) throws {
        func rejected(_ action: () throws -> Void) -> Bool { do { try action();return false } catch { return true } }
        var job = ShotJob.fixture(shot:26,title:"trial policy fixture")
        job.id = engine.manifest.appJobID;job.h3ReferenceEngine = engine
        job.h3FidelityChecks = (0..<4).map { index in
            var value = H3FidelityRecord(id:UUID(),kind:.motionReferenceDetail,directory:root.path,requestSHA256:ExecutionFocusSelfTests.hashA,originalSHA256:ExecutionFocusSelfTests.hashB,referenceEngine:engine)
            value.status = index == 0 ? "cancelled" : "failed"
            return value
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(job)
        try check("历史设置耗尽不能静默变成不限次数",!H3ReferenceEngine.canUse(engine,job:job),"no later instruction recorded yet")
        let instruction = H3ReferenceTrialPolicyInstruction(appJobID:job.id,engineRegistrationSHA256:engine.receiptSHA256,authorizationQuote:"取消这项试验的次数限制",authorizationSource:"isolated unit test instruction")
        let instructionBytes = try encoder.encode(instruction)
        let directory = root.appendingPathComponent("h3-reference-engines/" + job.id.uuidString + "/trial-policies/" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try before.write(to:directory.appendingPathComponent("previous-job.json"))
        try instructionBytes.write(to:directory.appendingPathComponent("instruction.json"))
        var receipt = H3ReferenceTrialPolicyReceipt(instruction:instruction,instructionSHA256:H3ABConfigurationReader.digest(instructionBytes),previousJobSHA256:H3ABConfigurationReader.digest(before),priorTrialCount:4,recordedAt:Date())
        func saveReceipt() throws -> H3ReferenceTrialPolicyBinding {
            let bytes = try encoder.encode(receipt),url = directory.appendingPathComponent("receipt.json")
            try bytes.write(to:url)
            return .init(instruction:instruction,receiptPath:url.path,receiptSHA256:H3ABConfigurationReader.digest(bytes))
        }
        let binding = try saveReceipt()
        job.h3ReferenceTrialPolicy = binding
        try binding.validate(jobID:job.id,engine:engine,workspace:root.path)
        try H3ReferenceEngine.validateTrialAllowance(engine,job:job,workspace:root.path,policy:binding,includingCurrent:false)
        try H3ReferenceEngine.validateTrialAllowance(engine,job:job,workspace:root.path,policy:binding,includingCurrent:true)
        try check("已取消次数限制实际允许超过旧上限",H3ReferenceEngine.canUse(engine,job:job),"prelaunch and worker guard both accept valid later instruction with four old attempts")
        try check("取消上限不清零历史或改原登记",H3ReferenceEngine.trialsUsed(in:job) == 4 && job.h3ReferenceEngine == engine && engine.manifest.maximumTrials == 2,"original historical manifest remains an immutable record")
        try check("界面显示当前不限次数",H3ReferenceEngine.trialStatus(job) == "次数不限 · 已记录 4 次试验","no stale two-run quota displayed")
        var unchanged = job;unchanged.h3ReferenceTrialPolicy = nil
        try check("新设置可单独撤去比较历史",try encoder.encode(unchanged) == before,"all prior experiment bytes and task fields preserved")
        try check("运行请求不能漏带当前次数设置",rejected { try H3ReferenceEngine.validateTrialAllowance(engine,job:job,workspace:root.path,policy:nil,includingCurrent:true) },"request snapshot must match current state")
        for field in 0..<6 {
            var bad = instruction
            switch field {
            case 0: bad.appJobID = UUID()
            case 1: bad.engineRegistrationSHA256 = ExecutionFocusSelfTests.hashB
            case 2: bad.authorizationQuote = ""
            case 3: bad.authorizationSource = ""
            case 4: bad.mode = "reset-counter"
            default: bad.scope = "download-any-model"
            }
            try check("次数指令范围核验\(field)",rejected { try bad.validate(jobID:job.id,engine:engine) },"job, engine, explicit instruction and existing-model scope remain checked")
        }
        var otherEngine = engine;otherEngine.manifest.helperSHA256 = ExecutionFocusSelfTests.hashB
        try check("取消次数不授权换引擎",rejected { try instruction.validate(jobID:job.id,engine:otherEngine) },"pinned runtime identity still enforced")
        receipt.priorTrialCount = 0
        let wrongCount = try saveReceipt()
        try check("审计不能抹去失败取消次数",rejected { try wrongCount.validate(jobID:job.id,engine:engine,workspace:root.path) },"count checked against archived previous job")
        receipt.priorTrialCount = 4;receipt.videoAccepted = true
        let accepting = try saveReceipt()
        try check("次数变更不能冒充视频接受",rejected { try accepting.validate(jobID:job.id,engine:engine,workspace:root.path) },"acceptance remains independent")
        receipt.videoAccepted = false;_ = try saveReceipt()
        try Data("changed instruction".utf8).write(to:directory.appendingPathComponent("instruction.json"))
        try check("篡改来源文件时执行拒绝",rejected { try H3ReferenceEngine.validateTrialAllowance(engine,job:job,workspace:root.path,policy:binding,includingCurrent:false) },"valid state labels cannot bypass frozen instruction bytes")
        try instructionBytes.write(to:directory.appendingPathComponent("instruction.json"))
        try Data("changed history".utf8).write(to:directory.appendingPathComponent("previous-job.json"))
        try check("篡改历史快照时执行拒绝",rejected { try binding.validate(jobID:job.id,engine:engine,workspace:root.path) },"archived job remains required")
        try before.write(to:directory.appendingPathComponent("previous-job.json"))
        var record = job.h3FidelityChecks![0]
        record.finding = .motionIdentityDrift
        record.guidance = H3FidelityGuidance.make(.motionIdentityDrift,shot:26,kind:.motionReferenceDetail)
        record.guidance?.nextStep = "两次历史授权已用完"
        let oldObservation = try encoder.encode(record)
        let current = record.guidanceForDisplay(in:job)
        try check("历史结论按当前次数设置显示",current?.nextStep.contains("次数限制已按用户指令取消") == true && current?.blocksQuality == true && current?.title == record.guidance?.title,"quality failure preserved while stale quota instruction is hidden")
        try check("显示投影不改冻结观察",try encoder.encode(record) == oldObservation,"no rewriting history to apply current policy")
        let decodedOld = try JSONDecoder().decode(ShotJob.self,from:before)
        try check("旧任务无需迁移次数字段",decodedOld.h3ReferenceTrialPolicy == nil && decodedOld.h3FidelityChecks?.allSatisfy { $0.referenceTrialPolicy == nil } == true,"optional fields keep old state and requests readable")
    }
}
