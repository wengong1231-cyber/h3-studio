import Foundation

@MainActor enum H3AutomationSelfTests {
    static func environment(root: URL,executable: URL,normalized: Bool = false,largeFirstInput: Bool = false) async throws -> (TaskStore,URL,UUID) {
        let runtime = try H3Mock.createRuntime(root:root.appendingPathComponent("runtime"),executable:executable)
        let work = URL(fileURLWithPath:runtime.workDirectory),inputs = work.appendingPathComponent("proposals/inputs")
        try FileManager.default.createDirectory(at:inputs,withIntermediateDirectories:true)
        for name in ["helper-marker","library-marker"] { try Data("CPU fixture marker".utf8).write(to:work.appendingPathComponent(name)) }
        let a = inputs.appendingPathComponent("A.png"),b = inputs.appendingPathComponent("B.png")
        let firstWidth = largeFirstInput ? 4096 : 768,firstHeight = largeFirstInput ? 2304 : 448
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:8,width:firstWidth,height:firstHeight),to:a,width:firstWidth,height:firstHeight)
        try FixtureWorker.savePNG(FixtureWorker.makeFrame(frame:30,width:768,height:448),to:b,width:768,height:448)
        var descriptor = try H3ABSelfTests.descriptor(work:work,first:a,last:b),values = descriptor["inputs"] as! [String:Any]
        for name in ["A","B"] {
            var value = values[name] as! [String:Any];value["normalized_visual_review_passed"] = false
            if !normalized { value["normalized_path"] = NSNull();value["normalized_sha256"] = NSNull() }
            values[name] = value
        }
        descriptor["inputs"] = values
        let source = work.appendingPathComponent("proposals/automatic.json")
        try JSONSerialization.data(withJSONObject:descriptor,options:[.sortedKeys,.prettyPrinted]).write(to:source)
        let store = try TaskStore(root:root.appendingPathComponent("workspace"),executable:executable,monitoring:false,h3Runtime:runtime)
        let id = try await store.importS41Configuration(source)
        return (store,source,id)
    }
    static func run(root: URL,executable: URL) async -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String,_ value: Bool,_ detail: String) throws {
            checks.append(.init(name:name,passed:value,detail:detail));print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { throw StudioError.invalid(name) }
        }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let (normal,_,id) = try await environment(root:root.appendingPathComponent("normal"),executable:executable)
            try check("导入无人工门槛且不自行执行",normal.canStartS41Workflow(id) && normal.launchCount == 0 && normal.state.jobs[0].h3ABConfiguration?.blockers.allSatisfy { !$0.contains("人工") } == true,"缺归一图仍可开始完整流程；导入不会启动 GPU")
            let first = Task { await normal.startAuthorizedS41(id) }
            try await StudioSelfTests.wait("automatic flow ownership") { normal.abWorkflowID == id || normal.activeJob?.id == id }
            normal.add(.fixture(shot:90,title:"串行保护",delay:0.01));normal.startQueue()
            await normal.startAuthorizedS41(id);await first.value
            try check("重复开始与跨引擎串行保护",normal.launchCount == 1 && normal.state.jobs[1].attempts.isEmpty,"自动流程持有唯一资源槽，重复点击与合成队列不会并发启动")
            try await StudioSelfTests.wait("automatic CPU candidate",timeout:30) { normal.activeJob == nil }
            let result = normal.state.jobs[0],configuration = result.h3ABConfiguration!
            let outputReport = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:result.h3Outcome!.reportPath))) as! [String:Any]
            try check("一次开始自动完成全部阶段",result.status == .completed && result.h3InputPreparation?.images.count == 2 && result.h3InputPreparation?.automaticValidationStatus == "completed" && result.h3Outcome?.technicalPass == true && result.h3AutomaticWorkflow?.status == "completed","真实CPU归一、输入解码、单镜生成与73帧严格检查连续完成")
            try check("自动检查不伪造人工或语义通过",!configuration.first.visuallyReviewed && !configuration.last.visuallyReviewed && configuration.automaticInputsValidated && configuration.first.automaticCheck?.semanticQualityAssessed == false && result.h3Outcome?.visualReview == "not_automatically_evaluated" && result.h3Outcome?.selectedForProduction == false && outputReport["status"] as? String == "technical_pass" && outputReport["operator_approval_required"] as? Bool == false && outputReport["semantic_quality_assessed"] as? Bool == false,"人工历史字段保持false，真实输出报告无人工放行要求，内容质量未冒称通过，正式成片未替换")
            try check("自动检查有实际回执与时间",result.h3InputPreparation?.automaticValidationStartedAt != nil && result.h3InputPreparation?.automaticValidationEndedAt != nil && result.h3InputPreparation?.automaticValidationReceiptPath.map { FileManager.default.fileExists(atPath:$0) } == true,"保存自动检查范围、实际输入指纹、开始/结束和无人工放行声明")
            let videoHash = try WorkspaceDigest.sha256(URL(fileURLWithPath:result.candidate!))
            await normal.startAuthorizedS41(id)
            try check("完成任务不重新生成",normal.launchCount == 1 && (try WorkspaceDigest.sha256(URL(fileURLWithPath:result.candidate!))) == videoHash,"已完成视频与单次投递回执保留")
            normal.shutdown()

            let (failure,path,failureID) = try await environment(root:root.appendingPathComponent("failure"),executable:executable,normalized:true)
            let descriptor = try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
            let b = (((descriptor["inputs"] as! [String:Any])["B"] as! [String:Any])["path"] as! String)
            try Data("corrupt after registration".utf8).write(to:URL(fileURLWithPath:b))
            await failure.startAuthorizedS41(failureID)
            try check("校验失败自动终止且不进入 GPU",failure.state.jobs[0].status == .failed && failure.launchCount == 0 && failure.state.jobs[0].error != nil && failure.state.jobs[0].h3AutomaticWorkflow?.status == "failed","真实指纹变化明确报错，没有假通过或无限重试")
            failure.shutdown()

            let (cancel,_,cancelID) = try await environment(root:root.appendingPathComponent("cancel"),executable:executable,largeFirstInput:true)
            let running = Task { await cancel.startAuthorizedS41(cancelID) }
            try await StudioSelfTests.wait("cancel automatic preparation") { cancel.abWorkflowID == cancelID }
            cancel.cancel(cancelID,source:"CPU test automatic workflow cancellation");await running.value
            try check("取消自动流程不接续视频",cancel.state.jobs[0].status == .cancelled && cancel.launchCount == 0 && cancel.abWorkflowID == nil && cancel.state.jobs[0].h3AutomaticWorkflow?.status == "cancelled","CPU与自动检查阶段可取消；取消后不误推进 H3")
            cancel.shutdown()

            let (recovery,_,recoveryID) = try await environment(root:root.appendingPathComponent("recovery"),executable:executable,normalized:true)
            var state = recovery.state;state.jobs[0].h3AutomaticWorkflow = .init(status:"running",phase:"input_validation",startedAt:Date())
            let recoveryRoot = recovery.root,runtime = recovery.h3Runtime;recovery.shutdown()
            // A separate workspace avoids retaining the original lock; all
            // references remain within this test's explicit mock root.
            let restoredRoot = root.appendingPathComponent("restored");try FileManager.default.createDirectory(at:restoredRoot,withIntermediateDirectories:true)
            try JSONEncoder().encode(state).write(to:restoredRoot.appendingPathComponent("state.json"))
            let restored = try TaskStore(root:restoredRoot,executable:executable,monitoring:false,h3Runtime:runtime)
            try check("中断恢复不重复派发",restored.state.jobs[0].id == recoveryID && restored.state.jobs[0].status == .interrupted && restored.state.jobs[0].h3AutomaticWorkflow?.status == "interrupted" && restored.launchCount == 0 && FileManager.default.fileExists(atPath:recoveryRoot.appendingPathComponent("state.json").path),"恢复步骤与错误，原工作区和文件保留，无自动耗费资源重生成")
            restored.shutdown()
        } catch { checks.append(.init(name:"异常",passed:false,detail:error.localizedDescription));print(error.localizedDescription) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to:root.appendingPathComponent("test-report.json"),options:.atomic) }
        return checks.contains(where: { !$0.passed }) ? 1 : 0
    }
}
