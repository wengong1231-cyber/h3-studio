import Foundation

enum WorkspaceMigrationTests {
    struct Check: Codable { var name: String; var passed: Bool; var detail: String }
    static func run(root: URL) -> Int32 {
        let fm = FileManager.default
        var checks: [Check] = []
        func check(_ name: String, _ value: Bool, _ detail: String) throws {
            checks.append(Check(name: name, passed: value, detail: detail))
            FileHandle.standardOutput.write(Data("\(value ? "PASS" : "FAIL") \(name): \(detail)\n".utf8))
            if !value { throw StudioError.invalid(name) }
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        func hashes(_ folder: URL) throws -> [String: String] {
            var result: [String: String] = [:]
            let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(folder.path.count + 1))] = try WorkspaceDigest.sha256(file)
            }
            return result
        }
        func state(_ folder: URL) throws -> WorkspaceState { try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: folder.appendingPathComponent("state.json"))) }
        func writeState(_ value: WorkspaceState, _ folder: URL) throws { try JSONEncoder().encode(value).write(to: folder.appendingPathComponent("state.json"), options: .atomic) }
        func fixture(_ name: String, active: Bool = false) throws -> (URL, WorkspaceMigrator) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let legacy = folder.appendingPathComponent("project/Data", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data().write(to: legacy.appendingPathComponent(".queue-lock"))
            try Data("old-owner-marker".utf8).write(to: legacy.appendingPathComponent("owner.json"))
            var completed = ShotJob.fixture(shot: 2, title: "已完成迁移夹具")
            let attempt = legacy.appendingPathComponent("candidates/\(completed.id)/attempt-1", isDirectory: true)
            try fm.createDirectory(at: attempt, withIntermediateDirectories: true)
            let candidate = attempt.appendingPathComponent("synthetic-candidate.mp4")
            try Data("synthetic migration bytes, not a generated video".utf8).write(to: candidate)
            try Data("fixture reference".utf8).write(to: attempt.appendingPathComponent("reference.png"))
            let archive = ["workspace": legacy.path, "outputDirectory": attempt.path, "ffmpeg": ExternalLocations.defaults.ffmpeg]
            try JSONSerialization.data(withJSONObject: archive).write(to: attempt.appendingPathComponent("request.json"))
            try JSONSerialization.data(withJSONObject: ["directory": attempt.path, "candidate": candidate.path]).write(to: attempt.appendingPathComponent("attempt-metrics.json"))
            try Data("原始日志路径 \(attempt.path)\n".utf8).write(to: attempt.appendingPathComponent("engine.log"))
            completed.status = active ? .running : .completed
            completed.candidate = candidate.path
            completed.reference = attempt.appendingPathComponent("reference.png").path
            completed.lastReference = folder.appendingPathComponent("external-reference.png").path
            completed.attempts = [Attempt(number: 1, startedAt: Date(timeIntervalSince1970: 100), status: .completed, directory: attempt.path, candidate: candidate.path)]
            let waiting = ShotJob(shot: 3, segment: "h3-pending", title: "H3 等待队列", prompt: "", requestedDuration: 2, engine: .h3, status: .blocked)
            var original = WorkspaceState(); original.jobs = [completed, waiting]; original.theme = "light"; original.orbX = -50; original.orbY = 417; original.samplingInterval = 10; original.monitoring = false
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            object["futureSchemaField"] = ["keep": "unchanged"]
            let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try data.write(to: legacy.appendingPathComponent("state.json"))
            try data.write(to: legacy.appendingPathComponent("state.backup.json"))
            return (legacy, WorkspaceMigrator(supportRoot: folder.appendingPathComponent("Application Support/\(AppIdentity.bundleID)", isDirectory: true)))
        }
        func fakeApp(_ folder: URL, marker: String, identity: String = AppIdentity.bundleID) throws -> URL {
            let app = folder.appendingPathComponent(AppIdentity.name + ".app", isDirectory: true)
            try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identity, "CFBundleExecutable": "WanshenjiH3Studio", "LSUIElement": false]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/MacOS/WanshenjiH3Studio"))
            return app
        }
        do {
            guard !fm.fileExists(atPath: root.path), root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root, !root.pathComponents.contains("sessions") else { throw StudioError.invalid("迁移测试必须使用新的独立目录。") }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let (legacy, migrator) = try fixture("successful")
            let baseline = try hashes(legacy)
            let original = try state(legacy)
            let plan = try migrator.plan(legacy: legacy)
            try check("迁移计划只读", !fm.fileExists(atPath: migrator.supportRoot.path) && plan.fileCount == baseline.count - 2 && plan.jobIDs == original.jobs.map(\.id) && !plan.sourceInUse, "原工作区不写入，计划不创建 Application Support")
            let receipt = try migrator.migrate(legacy: legacy)
            let copied = try state(migrator.standard)
            try check("复制校验并保留原 Data", try hashes(legacy) == baseline && receipt.files.allSatisfy { !$0.sourceSHA256.isEmpty && !$0.copiedSHA256.isEmpty } && receipt.originalPreserved, "逐文件 SHA-256，原 Data、owner、锁和输出逐字节保留")
            try check("镜头与偏好迁移完整", copied.jobs.map(\.id) == original.jobs.map(\.id) && copied.jobs.map(\.status) == original.jobs.map(\.status) && copied.theme == "light" && copied.orbX == -50 && copied.orbY == 417 && copied.samplingInterval == 10 && !copied.monitoring && copied.queuePaused, "保持队列顺序、候选、H3 等待、主题、悬浮球与采样设置")
            let migratedJob = copied.jobs[0]
            try check("候选及尝试路径重定位", migratedJob.candidate!.hasPrefix(migrator.standard.path + "/") && migratedJob.attempts[0].directory.hasPrefix(migrator.standard.path + "/") && migratedJob.attempts[0].candidate == migratedJob.candidate && fm.fileExists(atPath: migratedJob.candidate!), "仅新 state 与 backup 的应用自有路径变更")
            try check("引用范围精确", migratedJob.reference!.hasPrefix(migrator.standard.path + "/") && migratedJob.lastReference == original.jobs[0].lastReference, "自有参考图迁移，工作区外参考路径保持原值")
            let backup = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: migrator.standard.appendingPathComponent("state.backup.json")))
            try check("备份路径与未来字段保留", backup.jobs[0].candidate == migratedJob.candidate && (try JSONSerialization.jsonObject(with: Data(contentsOf: migrator.standard.appendingPathComponent("state.json"))) as! [String: Any])["futureSchemaField"] != nil, "有效备份同样重定位，未知未来字段不因 Codable 重写丢失")
            let archives = receipt.files.filter { $0.relativePath.hasSuffix("request.json") || $0.relativePath.hasSuffix("attempt-metrics.json") || $0.relativePath.hasSuffix("engine.log") }
            try check("历史请求和日志保留原文", archives.count == 3 && archives.allSatisfy { $0.sourceSHA256 == $0.copiedSHA256 }, "原始执行参数与旧路径保留作为审计，不伪装成在新路径执行")
            let settings = try migrator.loadSettings()!
            try check("外部模型与工具路径不迁移", settings.externalLocations == .defaults && plan.externalModelBytesMoved == 0 && !fm.fileExists(atPath: migrator.standard.appendingPathComponent("owner.json").path), "只持久保存项目、下载状态和 FFmpeg 的外部引用；不复制模型或运行 owner")
            var evolved = copied; evolved.jobs.append(.fixture(shot: 4, title: "迁移后新队列")); try writeState(evolved, migrator.standard)
            let added = migrator.standard.appendingPathComponent("candidates/new-output.mp4"); try Data("new output remains".utf8).write(to: added)
            let targetAfterNewOutput = try hashes(migrator.standard)
            let repeated = try migrator.migrate(legacy: legacy)
            try check("重复迁移不覆盖新增队列或产物", repeated.completedAt == receipt.completedAt && (try hashes(migrator.standard)) == targetAfterNewOutput && (try hashes(legacy)) == baseline, "第二次不复制、不覆盖、不删除；仍保留首个迁移记录")
            try migrator.switchWorkspace(to: "legacy")
            try check("回退可用且新结果仍保留", try migrator.loadSettings()?.activeWorkspace == "legacy" && hashes(migrator.standard) == targetAfterNewOutput && hashes(legacy) == baseline, "回退选择原快照，不合并两边后续变更")
            try migrator.switchWorkspace(to: "standard")
            try check("恢复标准工作区幂等", try migrator.loadSettings()?.activeWorkspace == "standard" && hashes(migrator.standard) == targetAfterNewOutput, "恢复选择新分支，候选与新队列保留")
            do {
                let context = try migrator.resolve(legacyHint: legacy)
                try check("标准版阻止旧版同时持有队列", context.root == migrator.standard && rejected { _ = try WorkspaceFileLease(legacy.appendingPathComponent(".queue-lock"), create: false) }, "安装版运行期间保持原 v0.2 锁，不产生两个独立队列")
                try check("标准版多实例与运行回退被拒绝", rejected { _ = try migrator.resolve(legacyHint: legacy) } && rejected { try migrator.switchWorkspace(to: "legacy") }, "全局实例锁与工作区锁阻止重复启动及运行中切换")
                withExtendedLifetime(context) {}
            }
            let (busyLegacy, busyMigrator) = try fixture("busy")
            do {
                let lock = try WorkspaceFileLease(busyLegacy.appendingPathComponent(".queue-lock"), create: false)
                try check("运行中的旧应用不被迁移", try busyMigrator.plan(legacy: busyLegacy).sourceInUse && rejected { _ = try busyMigrator.migrate(legacy: busyLegacy) } && !fm.fileExists(atPath: busyMigrator.supportRoot.path), "持锁时拒绝操作，连目标目录也不创建，不终止旧进程")
                withExtendedLifetime(lock) {}
            }
            let (activeLegacy, activeMigrator) = try fixture("active-state", active: true)
            try check("残留活动生成需要先安全恢复", rejected { _ = try activeMigrator.migrate(legacy: activeLegacy) } && !fm.fileExists(atPath: activeMigrator.supportRoot.path), "不因拿到文件锁就迁移可能仍存活的生成记录")
            let (beforeLegacy, beforeMigrator) = try fixture("before-publish")
            let beforeHashes = try hashes(beforeLegacy)
            try check("发布前失败可回退", rejected { _ = try beforeMigrator.migrate(legacy: beforeLegacy, fault: .beforePublish) } && !fm.fileExists(atPath: beforeMigrator.standard.path) && !fm.fileExists(atPath: beforeMigrator.settingsURL.path) && (try hashes(beforeLegacy)) == beforeHashes, "故障注入后无半成品标准工作区，原数据不变")
            _ = try beforeMigrator.migrate(legacy: beforeLegacy)
            try check("发布前失败后重试成功", fm.fileExists(atPath: beforeMigrator.standard.appendingPathComponent("state.json").path), "重新复制并校验完整工作区")
            let (afterLegacy, afterMigrator) = try fixture("after-publish")
            try check("目录发布后故障保留完整副本", rejected { _ = try afterMigrator.migrate(legacy: afterLegacy, fault: .afterPublish) } && fm.fileExists(atPath: afterMigrator.standard.appendingPathComponent("migration-receipt.json").path) && !fm.fileExists(atPath: afterMigrator.settingsURL.path), "原子发布成功但设置尚未提交，完整记录保留")
            let afterTarget = try hashes(afterMigrator.standard)
            _ = try afterMigrator.migrate(legacy: afterLegacy)
            try check("设置提交前崩溃可幂等恢复", try hashes(afterMigrator.standard) == afterTarget && afterMigrator.loadSettings()?.activeWorkspace == "standard", "校验原快照与全部副本后仅补写设置，不重复复制")
            let (changedLegacy, changedMigrator) = try fixture("changed-after-publish")
            _ = rejected { _ = try changedMigrator.migrate(legacy: changedLegacy, fault: .afterPublish) }
            var changed = try state(changedMigrator.standard); changed.jobs.append(.fixture(shot: 5, title: "崩溃窗口期间发生变更")); try writeState(changed, changedMigrator.standard)
            let changedHash = try hashes(changedMigrator.standard)
            try check("提交前副本变化需人工审查", rejected { _ = try changedMigrator.migrate(legacy: changedLegacy) } && (try hashes(changedMigrator.standard)) == changedHash && !fm.fileExists(atPath: changedMigrator.settingsURL.path), "不静默补写设置或覆盖发生变化的队列")
            let (unknownLegacy, unknownMigrator) = try fixture("unknown-file")
            try Data("unrecognized synthetic fixture".utf8).write(to: unknownLegacy.appendingPathComponent("model.weights"))
            try check("拒绝非应用文件与模型", rejected { _ = try unknownMigrator.migrate(legacy: unknownLegacy) } && !fm.fileExists(atPath: unknownMigrator.standard.path), "白名单以外文件不读取内容、不复制")
            let (linkedLegacy, linkedMigrator) = try fixture("linked-file")
            try fm.createSymbolicLink(atPath: linkedLegacy.appendingPathComponent("candidates/external-link").path, withDestinationPath: "/nonexistent-outside-fixture")
            try check("拒绝符号链接与受禁路径", rejected { _ = try linkedMigrator.migrate(legacy: linkedLegacy) } && rejected { _ = try migrator.plan(legacy: root.appendingPathComponent("sessions")) }, "在文件内容读取前拒绝链接和 sessions 路径")
            let (badLegacy, badMigrator) = try fixture("bad-state")
            try Data("invalid fixture JSON".utf8).write(to: badLegacy.appendingPathComponent("state.backup.json"))
            try check("无效备份不生成标准工作区", rejected { _ = try badMigrator.migrate(legacy: badLegacy) } && !fm.fileExists(atPath: badMigrator.standard.path), "保留损坏文件交给原应用恢复，不静默丢弃备份")
            let (targetLegacy, targetMigrator) = try fixture("existing-target")
            try fm.createDirectory(at: targetMigrator.standard, withIntermediateDirectories: true)
            let existing = targetMigrator.standard.appendingPathComponent("preserve.txt"); try Data("keep unrelated target".utf8).write(to: existing)
            try check("不覆盖没有迁移身份的目标", rejected { _ = try targetMigrator.migrate(legacy: targetLegacy) } && (try Data(contentsOf: existing)) == Data("keep unrelated target".utf8), "发现现有未知工作区立即停止，不合并或初始化覆盖")
            let fresh = WorkspaceMigrator(supportRoot: root.appendingPathComponent("fresh/Application Support/\(AppIdentity.bundleID)", isDirectory: true))
            do {
                let context = try fresh.resolve(legacyHint: nil)
                try check("无旧项目的安装独立定位", context.root == fresh.standard && context.settings.legacyWorkspace == nil && context.settings.externalLocations == .defaults, "默认路径由用户 Application Support 决定，与 app 包所在目录无关")
                withExtendedLifetime(context) {}
            }
            let (installLegacy, installMigrator) = try fixture("installer")
            let persistent = CodeSigningIdentity(identifier: AppIdentity.bundleID,
                designatedRequirement: "identifier \"" + AppIdentity.bundleID + "\" and certificate leaf = H\"" + String(repeating:"b",count:40) + "\"", certificateSHA256: [String(repeating: "a",count:64)], isAdHoc: false,leafCertificateSHA1:String(repeating:"b",count:40))
            let adhoc = CodeSigningIdentity(identifier: AppIdentity.bundleID,
                designatedRequirement: "cdhash old-build", certificateSHA256: [], isAdHoc: true)
            try check("正式安装拒绝临时签名", rejected {
                _ = try CodeSigningIdentity.validateUpgrade(candidate: adhoc,existing:nil,satisfiesExisting:false,allowInitialMigration:true)
            }, "没有证书不能通过首次迁移开关绕过签名身份校验")
            try check("固定身份首次安装",try !CodeSigningIdentity.validateUpgrade(candidate:persistent,existing:nil,satisfiesExisting:false,allowInitialMigration:false),"首次安装无需伪造旧权限")
            try check("临时身份迁移必须明确",rejected {
                _ = try CodeSigningIdentity.validateUpgrade(candidate:persistent,existing:adhoc,satisfiesExisting:false,allowInitialMigration:false)
            },"安装计划先披露一次性身份切换")
            try check("允许首次切换固定身份",try CodeSigningIdentity.validateUpgrade(candidate:persistent,existing:adhoc,satisfiesExisting:false,allowInitialMigration:true),"首次切换不复制或编辑TCC授权")
            try check("更新满足旧身份要求",try !CodeSigningIdentity.validateUpgrade(candidate:persistent,existing:persistent,satisfiesExisting:true,allowInitialMigration:false),"不同程序内容仍须满足旧证书身份")
            try check("同名换证书也拒绝",rejected {
                _ = try CodeSigningIdentity.validateUpgrade(candidate:persistent,existing:persistent,satisfiesExisting:false,allowInitialMigration:true)
            },"迁移开关不能覆盖已经固定的签名身份")
            var forged = persistent;forged.certificateSHA256 = []
            try check("仅标识符不能冒充固定签名",rejected {
                _ = try CodeSigningIdentity.validateUpgrade(candidate:forged,existing:persistent,satisfiesExisting:true,allowInitialMigration:true)
            },"必须包含实际签名证书，禁止identifier-only要求")
            var weak = persistent;weak.designatedRequirement = "identifier \"" + AppIdentity.bundleID + "\""
            try check("证书存在也不接受过宽身份要求",!weak.hasPersistentIdentity,"must pin the actual leaf certificate, not just embed any certificate")
            var foreignSigning = persistent;foreignSigning.identifier = "example.foreign"
            try check("签名标识符不能更换",rejected {
                _ = try CodeSigningIdentity.validateUpgrade(candidate:foreignSigning,existing:persistent,satisfiesExisting:true,allowInitialMigration:true)
            },"固定应用身份也约束签名标识符")
            let runningApp = URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let actualIdentity = try CodeSigningIdentity.inspect(runningApp)
            try check("实际编译应用包含固定签名证书",actualIdentity.hasPersistentIdentity && !actualIdentity.certificateSHA256.isEmpty,
                "直接读取本次真实签名包；本机自签名链不需要添加系统信任")
            try check("实际签名身份校验通过",try CodeSigningIdentity.satisfies(runningApp,requirement:actualIdentity.designatedRequirement),"真实证书约束成立，不仅是策略夹具")
            let source = try fakeApp(root.appendingPathComponent("installer/candidate", isDirectory: true), marker: "candidate executable")
            let appRoot = root.appendingPathComponent("installer/user Applications", isDirectory: true)
            let installer = UserAppInstaller(sourceApp: source, applicationsRoot: appRoot, migrator: installMigrator)
            let installBaseline = try hashes(installLegacy)
            let installationPlan = try installer.plan(legacyHint: installLegacy)
            try check("安装计划不创建用户目录", !fm.fileExists(atPath: appRoot.path) && !fm.fileExists(atPath: installMigrator.supportRoot.path) && installationPlan.targetApp == installer.target.path, "预览计划为只读，固定 app 名称与 ID")
            try check("签名失败不复制或迁移", rejected { _ = try installer.install(legacyHint: installLegacy, signatureVerifier: { _ in throw StudioError.invalid("fixture signature rejection") }) } && !fm.fileExists(atPath: installMigrator.supportRoot.path), "生产入口实际使用 codesign；夹具注入失败验证顺序")
            let firstInstall = try installer.install(legacyHint: installLegacy, signatureVerifier: { _ in })
            try check("安装到固定用户 Applications", firstInstall.installedApp == installer.target.path && firstInstall.previousAppBackup == nil && (try hashes(installer.target)) == hashes(source) && (try hashes(installLegacy)) == installBaseline && !firstInstall.launched && !firstInstall.systemDatabaseModified, "夹具安装只复制指定应用、迁移自有数据，不启动或修改系统数据库")
            let laterAssets = installLegacy.appendingPathComponent("static-inputs",isDirectory:true)
            try fm.createDirectory(at:laterAssets,withIntermediateDirectories:true)
            try Data("later source artwork fixture, not runtime state".utf8).write(to:laterAssets.appendingPathComponent("source.txt"))
            let activeBeforeUpgrade = try hashes(installMigrator.standard)
            let standardUpgradePlan = try installer.plan(legacyHint:installLegacy)
            try check("标准工作区升级不重迁旧工程目录",standardUpgradePlan.activeWorkspace == "standard" && standardUpgradePlan.legacyMigration == nil &&
                (try hashes(installMigrator.standard)) == activeBeforeUpgrade,"new project assets do not block installed-app upgrades; the active workspace remains authoritative and untouched")
            let targetFirst = try hashes(installer.target)
            try Data("upgraded fixture executable".utf8).write(to: source.appendingPathComponent("Contents/MacOS/WanshenjiH3Studio"))
            try check("替换失败保留原安装包", rejected { _ = try installer.install(legacyHint: installLegacy, signatureVerifier: { _ in }, failBeforePublish: true) } && (try hashes(installer.target)) == targetFirst, "发布前故障不改旧包，暂存副本自动清理")
            let upgrade = try installer.install(legacyHint: installLegacy, signatureVerifier: { _ in })
            try check("同身份升级有校验压缩备份", upgrade.previousAppBackup?.hasSuffix(".zip") == true && (try installer.archivedAppHashes(URL(fileURLWithPath: upgrade.previousAppBackup!))) == targetFirst && (try hashes(installer.target)) == hashes(source), "新包原子发布；旧版压缩包逐文件解压回读，只有固定正式应用入口")
            do {
                let context = try installMigrator.resolve(legacyHint: installLegacy)
                let unchanged = try hashes(installer.target)
                try check("运行时安装被互斥锁拒绝", rejected { _ = try installer.install(legacyHint: installLegacy, signatureVerifier: { _ in }) } && (try hashes(installer.target)) == unchanged, "安装必须先正常退出镜生 H3，不终止应用或外部下载")
                withExtendedLifetime(context) {}
            }
            let foreignRoot = root.appendingPathComponent("installer/foreign Applications", isDirectory: true)
            let foreignApp = try fakeApp(foreignRoot, marker: "foreign app", identity: "example.foreign")
            let foreignHash = try hashes(foreignApp)
            let foreign = UserAppInstaller(sourceApp: source, applicationsRoot: foreignRoot, migrator: installMigrator)
            try check("不覆盖同名不同身份应用", rejected { _ = try foreign.install(legacyHint: installLegacy, signatureVerifier: { _ in }) } && (try hashes(foreignApp)) == foreignHash, "目标身份不符时不迁移、不替换、不备份读取其他应用")
            let cleanInstaller = UserAppInstaller(sourceApp: source, applicationsRoot: root.appendingPathComponent("clean-install/user Applications", isDirectory: true),
                migrator: WorkspaceMigrator(supportRoot: root.appendingPathComponent("clean-install/Application Support/\(AppIdentity.bundleID)", isDirectory: true)))
            let cleanResult = try cleanInstaller.install(legacyHint: nil, signatureVerifier: { _ in })
            try check("无 Data 的首次安装完整", cleanResult.workspace == cleanInstaller.migrator.standard.path && fm.fileExists(atPath: cleanInstaller.target.path) && cleanInstaller.migrator.loadSettings()?.legacyWorkspace == nil, "Applications 和标准工作区均不存在时正常创建，不依赖工程 Data")
            let report: [String: Any] = ["passed": true, "checks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(checks)), "testRoot": root.path,
                "realUserDataMigrated": false, "realUserAppInstalled": false, "realH3Launched": false, "nativeUIExecuted": false, "date": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("migration-test-report.json"))
            return 0
        } catch {
            checks.append(Check(name: "unexpected error", passed: false, detail: error.localizedDescription))
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("migration-test-report.json")) }
            return 1
        }
    }
}
