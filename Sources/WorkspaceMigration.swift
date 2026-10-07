import Foundation
import CryptoKit
import Darwin

struct ExternalLocations: Codable, Equatable {
    var originalProject: String
    var modelStatusRoot: String
    var ffmpeg: String
    static var defaults: Self { Self(originalProject: AppIdentity.originalProject, modelStatusRoot: AppIdentity.modelStatusRoot.path, ffmpeg: AppIdentity.ffmpeg) }
}

struct WorkspaceSettings: Codable {
    var version = 1
    var activeWorkspace = "standard"
    var legacyWorkspace: String?
    var externalLocations = ExternalLocations.defaults
}

struct MigrationFile: Codable {
    var relativePath: String
    var bytes: Int64
    var sourceSHA256: String
    var copiedSHA256: String
}
struct WorkspaceMigrationReceipt: Codable {
    var version = 1
    var bundleID = AppIdentity.bundleID
    var legacyWorkspace: String
    var standardWorkspace: String
    var originalStateSHA256: String
    var copiedStateSHA256: String
    var completedAt: Date
    var files: [MigrationFile]
    var originalPreserved = true
    var externalLocations = ExternalLocations.defaults
}
struct WorkspaceMigrationPlan: Codable {
    var source: String
    var destination: String
    var fileCount: Int
    var bytesToCopy: Int64
    var jobIDs: [UUID]
    var sourceHasActiveTasks: Bool
    var sourceInUse: Bool
    var filesWithRebasedPaths = ["state.json", "state.backup.json"]
    var archivedRequestsAndLogsPreserved = true
    var externalLocations = ExternalLocations.defaults
    var externalModelBytesMoved: Int64 = 0
}

final class WorkspaceFileLease {
    private var fd: Int32 = -1
    init(_ url: URL, create: Bool) throws {
        let flags = create ? O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW : O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let handle = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard handle >= 0 else { throw StudioError.invalid("无法打开工作区锁：\(url.lastPathComponent)") }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { close(handle); throw StudioError.invalid("工作区仍由镜生 H3 使用。请先正常退出原应用；不会停止独立模型下载。") }
        fd = handle
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}

final class ResolvedWorkspace {
    let root: URL
    let settings: WorkspaceSettings
    // Keep a global lease and the original v0.2 queue lease, so the old and new app
    // cannot run two independent queues after the data has been copied.
    private let leases: [WorkspaceFileLease]
    init(root: URL, settings: WorkspaceSettings, leases: [WorkspaceFileLease]) { self.root = root; self.settings = settings; self.leases = leases }
}

enum WorkspaceDigest {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkspaceMigrator {
    enum Fault { case none, beforePublish, afterPublish }
    let supportRoot: URL
    var standard: URL { supportRoot.appendingPathComponent("Workspace", isDirectory: true) }
    var settingsURL: URL { supportRoot.appendingPathComponent("settings.json") }
    private let fm = FileManager.default
    static var defaultSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
    }
    static func legacyHint(bundle: Bundle = .main, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL? {
        guard let url = bundle.url(forResource: "LegacyWorkspace", withExtension: "json") else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        guard let relative = object?["relativeToHome"], !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.split(separator: "/").contains("sessions") else { throw StudioError.invalid("旧工作区定位信息无效。") }
        return home.appendingPathComponent(relative, isDirectory: true)
    }
    private func validateRoot(_ root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path == root.path,
              root.resolvingSymlinksInPath().path == root.path, !root.pathComponents.contains("sessions") else { throw StudioError.invalid("工作区路径不能含符号链接、跳转或 sessions。") }
    }
    private func stateObject(_ file: URL) throws -> [String: Any] {
        try validateRoot(file)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw StudioError.invalid("状态文件不是普通文件。") }
        let bytes = values.fileSize ?? 0
        guard bytes <= 67_108_864 else { throw StudioError.invalid("状态文件超过迁移大小上限。") }
        let data = try Data(contentsOf: file)
        let typed = try JSONDecoder().decode(WorkspaceState.self, from: data)
        guard typed.version == 1, typed.jobs.count <= 2000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudioError.invalid("旧工作区状态版本无效。") }
        return object
    }
    private func inventory(_ legacy: URL) throws -> [(URL, String, Int64)] {
        try validateRoot(legacy); try validateRoot(supportRoot)
        guard supportRoot != legacy, !supportRoot.path.hasPrefix(legacy.path + "/"), !legacy.path.hasPrefix(supportRoot.path + "/") else { throw StudioError.invalid("源与目标工作区不能相互包含。") }
        var rows: [(URL, String, Int64)] = []
        guard let enumerator = fm.enumerator(at: legacy, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { throw StudioError.invalid("无法列出旧工作区。") }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw StudioError.invalid("旧工作区含符号链接，拒绝复制外部内容。") }
            let relative = String(file.path.dropFirst(legacy.path.count + 1))
            let parts = file.pathComponents.dropFirst(legacy.pathComponents.count)
            guard !parts.contains("sessions") else { throw StudioError.invalid("不读取 sessions。") }
            if relative == "owner.json" || relative == ".queue-lock" { continue }
            if values.isDirectory == true {
                guard relative == "candidates" || relative.hasPrefix("candidates/") || relative == "h3-dispatch" else { throw StudioError.invalid("旧工作区含非应用目录：\(relative)") }
                continue
            }
            guard values.isRegularFile == true else { throw StudioError.invalid("旧工作区含非普通文件。") }
            let topAllowed = relative == "state.json" || relative == "state.backup.json" || relative == "startup-phases.jsonl" || (relative.hasPrefix("state-damaged-") && file.pathExtension == "json")
            let candidateAllowed = relative.hasPrefix("candidates/") && (["mp4", "mov", "webm", "png", "jpg", "jpeg", "ppm", "log"].contains(file.pathExtension.lowercased()) || ["request.json", "h3-request.json", "resources.json", "attempt-metrics.json", "generation.json"].contains(file.lastPathComponent))
            let dispatchAllowed = relative.hasPrefix("h3-dispatch/") && parts.count == 2 && file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent.count == 64 && file.deletingPathExtension().lastPathComponent.allSatisfy(\.isHexDigit)
            guard topAllowed || candidateAllowed || dispatchAllowed else { throw StudioError.invalid("旧工作区含非应用产物：\(relative)。请先审查，不自动读取或复制。") }
            rows.append((file, relative, Int64(values.fileSize ?? 0)))
            guard rows.count <= 200_000 else { throw StudioError.invalid("工作区文件数超过迁移上限。") }
        }
        return rows.sorted { $0.1 < $1.1 }
    }
    func plan(legacy: URL) throws -> WorkspaceMigrationPlan {
        let rows = try inventory(legacy)
        _ = try stateObject(legacy.appendingPathComponent("state.json"))
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: legacy.appendingPathComponent("state.json")))
        if fm.fileExists(atPath: legacy.appendingPathComponent("state.backup.json").path) { _ = try stateObject(legacy.appendingPathComponent("state.backup.json")) }
        var inUse = false
        if fm.fileExists(atPath: legacy.appendingPathComponent(".queue-lock").path) {
            do { let lease = try WorkspaceFileLease(legacy.appendingPathComponent(".queue-lock"), create: false); withExtendedLifetime(lease) {} } catch { inUse = true }
        }
        return WorkspaceMigrationPlan(source: legacy.path, destination: standard.path, fileCount: rows.count, bytesToCopy: rows.reduce(0) { $0 + $1.2 }, jobIDs: state.jobs.map(\.id), sourceHasActiveTasks: state.jobs.contains { $0.status.isActive }, sourceInUse: inUse)
    }
    func loadSettings() throws -> WorkspaceSettings? {
        try validateRoot(supportRoot)
        guard fm.fileExists(atPath: settingsURL.path) else { return nil }
        try validateRoot(settingsURL)
        guard (try settingsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw StudioError.invalid("工作区设置过大。") }
        let settings = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(contentsOf: settingsURL))
        guard settings.version == 1, ["standard", "legacy"].contains(settings.activeWorkspace), settings.activeWorkspace != "legacy" || settings.legacyWorkspace != nil,
              [settings.externalLocations.originalProject, settings.externalLocations.modelStatusRoot, settings.externalLocations.ffmpeg].allSatisfy({ $0.hasPrefix("/") && !URL(fileURLWithPath: $0).pathComponents.contains("sessions") }) else { throw StudioError.invalid("工作区设置无效，已保留原文件。") }
        return settings
    }
    private func saveSettings(_ settings: WorkspaceSettings) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
    private func rebase(_ value: String, source: URL) -> String {
        guard value.hasPrefix("/") else { return value }
        let normalized = URL(fileURLWithPath: value).standardizedFileURL.path
        if normalized == source.path { return standard.path }
        guard normalized.hasPrefix(source.path + "/") else { return value }
        return standard.path + normalized.dropFirst(source.path.count)
    }
    private func rebasedState(_ file: URL, source: URL) throws -> Data {
        var object = try stateObject(file)
        var jobs = object["jobs"] as? [[String: Any]] ?? []
        for i in jobs.indices {
            for key in ["reference", "lastReference", "candidate"] { if let value = jobs[i][key] as? String { jobs[i][key] = rebase(value, source: source) } }
            var attempts = jobs[i]["attempts"] as? [[String: Any]] ?? []
            for a in attempts.indices { for key in ["directory", "candidate"] { if let value = attempts[a][key] as? String { attempts[a][key] = rebase(value, source: source) } } }
            jobs[i]["attempts"] = attempts
        }
        object["jobs"] = jobs; object["queuePaused"] = true
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
    private func receipt() throws -> WorkspaceMigrationReceipt {
        try validateRoot(standard)
        let file = standard.appendingPathComponent("migration-receipt.json")
        try validateRoot(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 67_108_864 else { throw StudioError.invalid("迁移记录过大。") }
        let result = try JSONDecoder().decode(WorkspaceMigrationReceipt.self, from: Data(contentsOf: file))
        guard result.version == 1, result.bundleID == AppIdentity.bundleID, result.standardWorkspace == standard.path, result.originalPreserved,
              result.files.count <= 200_000, result.files.allSatisfy({ !$0.relativePath.isEmpty && !$0.relativePath.hasPrefix("/") && !$0.relativePath.split(separator: "/").contains("..") && !$0.relativePath.split(separator: "/").contains("sessions") }) else { throw StudioError.invalid("迁移记录不匹配，拒绝覆盖现有工作区。") }
        return result
    }
    @discardableResult func migrate(legacy: URL, fault: Fault = .none) throws -> WorkspaceMigrationReceipt {
        try validateRoot(legacy); try validateRoot(supportRoot)
        // The original lock is acquired before creating any real Application Support data.
        let originalLease = try WorkspaceFileLease(legacy.appendingPathComponent(".queue-lock"), create: false)
        defer { withExtendedLifetime(originalLease) {} }
        _ = try stateObject(legacy.appendingPathComponent("state.json"))
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: legacy.appendingPathComponent("state.json")))
        guard !state.jobs.contains(where: { $0.status.isActive }) else { throw StudioError.invalid("旧工作区仍记录活动生成任务，先在原应用中安全结束或恢复，未迁移。") }
        try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let migrationLease = try WorkspaceFileLease(supportRoot.appendingPathComponent(".migration-lock"), create: true)
        defer { withExtendedLifetime(migrationLease) {} }
        if fm.fileExists(atPath: standard.path) {
            let existing = try receipt()
            guard existing.legacyWorkspace == legacy.path else { throw StudioError.invalid("目标已有另一工作区，拒绝覆盖或合并。") }
            if let settings = try loadSettings() {
                guard settings.legacyWorkspace == legacy.path else { throw StudioError.invalid("目标设置与迁移记录不匹配。") }
                return existing // Never recopy or overwrite data added after the first migration.
            }
            guard try WorkspaceDigest.sha256(legacy.appendingPathComponent("state.json")) == existing.originalStateSHA256,
                  try WorkspaceDigest.sha256(standard.appendingPathComponent("state.json")) == existing.copiedStateSHA256 else { throw StudioError.invalid("未完成迁移后的状态发生变化，需要先审查，未覆盖。") }
            for file in existing.files {
                let target = standard.appendingPathComponent(file.relativePath)
                try validateRoot(target)
                guard try WorkspaceDigest.sha256(target) == file.copiedSHA256 else { throw StudioError.invalid("未完成迁移的文件校验不匹配。") }
            }
            try saveSettings(WorkspaceSettings(legacyWorkspace: legacy.path, externalLocations: existing.externalLocations))
            return existing
        }
        guard try loadSettings() == nil else { throw StudioError.invalid("已有工作区配置但数据缺失，拒绝初始化覆盖。") }
        let rows = try inventory(legacy)
        if fm.fileExists(atPath: legacy.appendingPathComponent("state.backup.json").path) { _ = try stateObject(legacy.appendingPathComponent("state.backup.json")) }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.2 }
        let available = try supportRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(available) > bytes + 268_435_456 else { throw StudioError.invalid("没有足够空间保留原 Data 并复制新工作区。") }
        for job in state.jobs where job.status == .completed {
            if let path = job.candidate { guard fm.fileExists(atPath: path) else { throw StudioError.invalid("已完成候选缺失，未迁移或删除原记录。") } }
        }
        let staging = supportRoot.appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        var copied: [MigrationFile] = []
        for (source, relative, size) in rows {
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceHash = try WorkspaceDigest.sha256(source)
            try fm.copyItem(at: source, to: target)
            guard try WorkspaceDigest.sha256(target) == sourceHash else { throw StudioError.invalid("复制文件校验失败，未替换工作区。") }
            if relative == "state.json" || relative == "state.backup.json" { try rebasedState(source, source: legacy).write(to: target, options: .atomic) }
            copied.append(MigrationFile(relativePath: relative, bytes: size, sourceSHA256: sourceHash, copiedSHA256: try WorkspaceDigest.sha256(target)))
        }
        _ = try stateObject(staging.appendingPathComponent("state.json"))
        let record = WorkspaceMigrationReceipt(legacyWorkspace: legacy.path, standardWorkspace: standard.path,
            originalStateSHA256: try WorkspaceDigest.sha256(legacy.appendingPathComponent("state.json")),
            copiedStateSHA256: try WorkspaceDigest.sha256(staging.appendingPathComponent("state.json")), completedAt: Date(), files: copied)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: staging.appendingPathComponent("migration-receipt.json"), options: .withoutOverwriting)
        if case .beforePublish = fault { throw StudioError.invalid("测试：发布前中断") }
        try fm.moveItem(at: staging, to: standard) // Publish a complete verified directory in one rename.
        if case .afterPublish = fault { throw StudioError.invalid("测试：发布后设置提交前中断") }
        try saveSettings(WorkspaceSettings(legacyWorkspace: legacy.path))
        return record
    }
    func switchWorkspace(to mode: String) throws {
        guard ["legacy", "standard"].contains(mode), var settings = try loadSettings(), let legacyPath = settings.legacyWorkspace else { throw StudioError.invalid("没有可回退的迁移配置。") }
        try validateRoot(URL(fileURLWithPath: legacyPath, isDirectory: true)); try validateRoot(standard)
        let global = try WorkspaceFileLease(supportRoot.appendingPathComponent(".instance-lock"), create: true)
        let original = try WorkspaceFileLease(URL(fileURLWithPath: legacyPath).appendingPathComponent(".queue-lock"), create: false)
        var standardLease: WorkspaceFileLease?
        if fm.fileExists(atPath: standard.appendingPathComponent(".queue-lock").path) { standardLease = try WorkspaceFileLease(standard.appendingPathComponent(".queue-lock"), create: false) }
        defer { withExtendedLifetime([global, original, standardLease].compactMap { $0 }) {} }
        let originalState = URL(fileURLWithPath: legacyPath).appendingPathComponent("state.json")
        let standardState = standard.appendingPathComponent("state.json")
        _ = try stateObject(originalState); _ = try stateObject(standardState)
        for file in [originalState, standardState] {
            let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: file))
            guard !state.jobs.contains(where: { $0.status.isActive }) else { throw StudioError.invalid("工作区仍记录活动任务，请在当前应用中安全恢复后再切换。") }
        }
        settings.activeWorkspace = mode; try saveSettings(settings)
    }
    func resolve(legacyHint: URL?) throws -> ResolvedWorkspace {
        try validateRoot(supportRoot)
        var settings = try loadSettings()
        if settings == nil {
            if let legacyHint, fm.fileExists(atPath: legacyHint.appendingPathComponent("state.json").path) { try migrate(legacy: legacyHint); settings = try loadSettings() }
            else {
                guard !fm.fileExists(atPath: standard.path) else { throw StudioError.invalid("现有标准工作区缺少配置，未覆盖；请使用明确的迁移来源恢复。") }
                try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
                let initial = WorkspaceSettings(); try saveSettings(initial); settings = initial
            }
        }
        guard let settings else { throw StudioError.invalid("没有有效工作区配置。") }
        var leases = [try WorkspaceFileLease(supportRoot.appendingPathComponent(".instance-lock"), create: true)]
        let root: URL
        if settings.activeWorkspace == "legacy", let path = settings.legacyWorkspace { root = URL(fileURLWithPath: path, isDirectory: true) }
        else {
            root = standard
            if let path = settings.legacyWorkspace, fm.fileExists(atPath: path) { leases.append(try WorkspaceFileLease(URL(fileURLWithPath: path).appendingPathComponent(".queue-lock"), create: false)) }
        }
        try validateRoot(root)
        return ResolvedWorkspace(root: root, settings: settings, leases: leases)
    }
}
