import Foundation
import Darwin

struct InstallationPlan: Codable {
    var sourceApp: String
    var targetApp: String
    var bundleID = AppIdentity.bundleID
    var version = AppIdentity.version
    var supportRoot: String
    var activeWorkspace: String?
    var legacyMigration: WorkspaceMigrationPlan?
    var existingTarget: Bool
    var installedOrLaunched = false
    var systemDatabaseModified = false
}

struct InstallationReceipt: Codable {
    var bundleID = AppIdentity.bundleID
    var version = AppIdentity.version
    var installedApp: String
    var executableSHA256: String
    var previousAppBackup: String?
    var workspace: String
    var completedAt: Date
    var launched = false
    var systemDatabaseModified = false
}

struct UserAppInstaller {
    let sourceApp: URL
    let applicationsRoot: URL
    let migrator: WorkspaceMigrator
    private let fm = FileManager.default
    var target: URL { applicationsRoot.appendingPathComponent(AppIdentity.name + ".app", isDirectory: true) }
    static var defaultApplicationsRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true) }

    private func safePath(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.path, url.resolvingSymlinksInPath().path == url.path,
              !url.pathComponents.contains("sessions") else { throw StudioError.invalid("安装路径不能含符号链接、跳转或 sessions。") }
    }
    private func validateApp(_ url: URL) throws {
        try safePath(url)
        guard url.lastPathComponent == AppIdentity.name + ".app" else { throw StudioError.invalid("安装源的固定应用名称不匹配。") }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        try safePath(infoURL)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == AppIdentity.bundleID,
              info?["CFBundleExecutable"] as? String == "WanshenjiH3Studio",
              info?["LSUIElement"] as? Bool == false else { throw StudioError.invalid("目标已有不同应用或不兼容应用，拒绝覆盖。") }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw StudioError.invalid("无法检查应用包。") }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw StudioError.invalid("应用包含外部链接或特殊文件，拒绝安装。") }
        }
    }
    private func verifySignature(_ url: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError.invalid("应用签名校验失败，未安装。") }
    }
    private func fileHashes(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw StudioError.invalid("无法校验应用包。") }
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count + 1))] = try WorkspaceDigest.sha256(file)
        }
        return result
    }
    private func archiveCommand(_ arguments: [String]) throws {
        let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments = arguments;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError.invalid("恢复压缩包创建或回读失败，未替换正式应用。") }
    }
    func archivedAppHashes(_ archive: URL) throws -> [String:String] {
        try safePath(archive)
        let check = archive.deletingLastPathComponent().appendingPathComponent(".verify-" + UUID().uuidString,isDirectory:true)
        defer { try? fm.removeItem(at:check) }
        try archiveCommand(["-x","-k",archive.path,check.path])
        let restored = check.appendingPathComponent(AppIdentity.name + ".app",isDirectory:true)
        try validateApp(restored)
        return try fileHashes(restored)
    }
    func plan(legacyHint: URL?) throws -> InstallationPlan {
        try safePath(applicationsRoot); try validateApp(sourceApp)
        let exists = fm.fileExists(atPath: target.path)
        if exists { try validateApp(target) }
        let settings = try migrator.loadSettings()
        var migration: WorkspaceMigrationPlan?
        // Once standard storage is active, the old project folder is only
        // historical evidence. New source assets there are not a new migration.
        // resolve() still verifies the configured workspace and all leases.
        if settings?.activeWorkspace != "standard",let legacyHint,
           fm.fileExists(atPath: legacyHint.appendingPathComponent("state.json").path) {
            migration = try migrator.plan(legacy: legacyHint)
        }
        return InstallationPlan(sourceApp: sourceApp.path, targetApp: target.path, supportRoot: migrator.supportRoot.path,
            activeWorkspace: settings?.activeWorkspace, legacyMigration: migration, existingTarget: exists)
    }
    // Dependency injection is limited to isolated fixture tests. CLI installation always
    // uses codesign and the fixed user Applications destination, never launches the app.
    func install(legacyHint: URL?, signatureVerifier: ((URL) throws -> Void)? = nil, failBeforePublish: Bool = false) throws -> InstallationReceipt {
        _ = try plan(legacyHint: legacyHint)
        guard sourceApp != target else { throw StudioError.invalid("请从候选构建执行安装，不能覆盖正在使用的源应用包。") }
        if let signatureVerifier { try signatureVerifier(sourceApp) } else { try verifySignature(sourceApp) }
        let context = try migrator.resolve(legacyHint: legacyHint)
        try fm.createDirectory(at: context.root, withIntermediateDirectories: true)
        let targetWorkspaceLease = try WorkspaceFileLease(context.root.appendingPathComponent(".queue-lock"), create: true)
        defer { withExtendedLifetime((context, targetWorkspaceLease)) {} }
        try safePath(applicationsRoot)
        try fm.createDirectory(at: applicationsRoot, withIntermediateDirectories: true)
        let staging = applicationsRoot.appendingPathComponent(".镜生-H3-install-\(UUID().uuidString).app", isDirectory: true)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        let hashes = try fileHashes(sourceApp)
        try fm.copyItem(at: sourceApp, to: staging)
        guard try fileHashes(staging) == hashes else { throw StudioError.invalid("安装副本与候选包不一致，未替换应用。") }
        if let signatureVerifier { try signatureVerifier(staging) } else { try verifySignature(staging) }
        var backup: URL?
        if fm.fileExists(atPath: target.path) {
            try validateApp(target)
            let folder = migrator.supportRoot.appendingPathComponent("InstallBackups/\(UUID().uuidString)", isDirectory: true)
            try safePath(folder); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let oldCopy = folder.appendingPathComponent(AppIdentity.name + ".zip")
            let oldHashes = try fileHashes(target)
            try archiveCommand(["-c","-k","--keepParent",target.path,oldCopy.path])
            guard try archivedAppHashes(oldCopy) == oldHashes else { throw StudioError.invalid("旧安装包恢复压缩包回读不一致，未替换应用。") }
            backup = oldCopy
        }
        if failBeforePublish { throw StudioError.invalid("测试：安装发布前中断") }
        if fm.fileExists(atPath: target.path) {
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else { throw StudioError.invalid("无法原子替换应用；原应用与备份已保留。") }
        } else { try fm.moveItem(at: staging, to: target) }
        let record = InstallationReceipt(installedApp: target.path,
            executableSHA256: try WorkspaceDigest.sha256(target.appendingPathComponent("Contents/MacOS/WanshenjiH3Studio")),
            previousAppBackup: backup?.path, workspace: context.root.path, completedAt: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: migrator.supportRoot.appendingPathComponent("installation-receipt.json"), options: .atomic)
        return record
    }
}

enum WorkspaceCommand {
    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func run(arguments: [String]) -> Int32? {
        let flags = ["--migration-plan", "--migrate-workspace", "--rollback-workspace", "--resume-standard-workspace", "--installation-plan", "--install-user-app", "--migration-self-test"]
        let supplied = flags.filter { arguments.contains($0) }
        guard let flag = supplied.first else { return nil }
        do {
            guard supplied.count == 1 else { throw StudioError.invalid("每次只能选择一种工作区操作。") }
            func value(_ key: String) throws -> String {
                guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw StudioError.invalid("参数缺少路径：\(key)") }
                return arguments[index + 1]
            }
            if flag == "--migration-self-test" { return WorkspaceMigrationTests.run(root: URL(fileURLWithPath: try value(flag), isDirectory: true)) }
            let migrator = WorkspaceMigrator(supportRoot: WorkspaceMigrator.defaultSupportRoot)
            let legacy: URL?
            if arguments.contains("--legacy-workspace") { legacy = URL(fileURLWithPath: try value("--legacy-workspace"), isDirectory: true).standardizedFileURL }
            else { legacy = try WorkspaceMigrator.legacyHint() }
            switch flag {
            case "--migration-plan": try emit(migrator.plan(legacy: URL(fileURLWithPath: try value(flag), isDirectory: true).standardizedFileURL))
            case "--migrate-workspace":
                guard arguments.contains("--apply") else { throw StudioError.invalid("复制迁移需要明确 --apply；先使用 --migration-plan 审查。") }
                try emit(migrator.migrate(legacy: URL(fileURLWithPath: try value(flag), isDirectory: true).standardizedFileURL))
            case "--rollback-workspace", "--resume-standard-workspace":
                guard arguments.contains("--apply") else { throw StudioError.invalid("切换工作区需要明确 --apply。") }
                try migrator.switchWorkspace(to: flag == "--rollback-workspace" ? "legacy" : "standard")
                try emit(migrator.loadSettings())
            case "--installation-plan", "--install-user-app":
                let source = URL(fileURLWithPath: arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let installer = UserAppInstaller(sourceApp: source, applicationsRoot: UserAppInstaller.defaultApplicationsRoot, migrator: migrator)
                if flag == "--installation-plan" { try emit(installer.plan(legacyHint: legacy)) }
                else {
                    guard arguments.contains("--apply") else { throw StudioError.invalid("安装需要明确 --apply；先使用 --installation-plan 审查。") }
                    try emit(installer.install(legacyHint: legacy))
                }
            default: break
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); return 1
        }
    }
}
