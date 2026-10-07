import Foundation
import Darwin
import CryptoKit

struct ModelStatusReadValue: Sendable {
    var snapshot: DownloadSnapshot
    var freeBytes: Int64?
    var quantizedAdditionalBytes: Int64?
    var verification: ModelPreparationVerification
}
enum ModelStatusReadFailure: String, Error, Sendable {
    case unavailable, accessDenied, invalidManifest, invalidStatus, invalidPath, unsafeFile, oversized
    var message: String {
        switch self {
        case .accessDenied: return "文件访问被拒绝 · 未确认模型状态。"
        case .invalidManifest: return "恢复清单无效，未确认模型状态。"
        case .invalidStatus: return "恢复状态与清单不匹配，保留上次快照。"
        case .invalidPath, .unsafeFile: return "恢复状态来源不是核准的普通本地文件。"
        case .oversized: return "恢复状态超过大小上限，未读取。"
        case .unavailable: return "恢复状态暂不可读，保留上次快照。"
        }
    }
}
typealias ModelStatusReadResult = Result<ModelStatusReadValue, ModelStatusReadFailure>

enum ModelStatusReader {
    static func safeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !["sessions", "credentials", "secrets"].contains($0.lowercased()) }
    }
    static func isHash(_ value: String, length: Int) -> Bool { value.count == length && value.allSatisfy(\.isHexDigit) }
    private static func ordinary(_ url: URL, limit: Int64? = nil, bytes: Int64? = nil) throws {
        guard url.isFileURL, url.standardizedFileURL == url, url.resolvingSymlinksInPath() == url,
              !url.pathComponents.contains(where: { ["sessions", "credentials", "secrets"].contains($0.lowercased()) }) else { throw ModelStatusReadFailure.invalidPath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ModelStatusReadFailure.unsafeFile }
        guard let size = values.fileSize else { throw ModelStatusReadFailure.unavailable }
        if let limit, Int64(size) > limit { throw ModelStatusReadFailure.oversized }
        if let bytes, Int64(size) != bytes { throw ModelStatusReadFailure.invalidStatus }
    }
    static func requireFile(_ url: URL, bytes: Int64? = nil, limit: Int? = nil) throws {
        try ordinary(url, limit: limit.map(Int64.init), bytes: bytes)
    }
    static func bounded(_ url: URL, limit: Int) throws -> Data {
        try ordinary(url, limit: Int64(limit))
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == EACCES || errno == EPERM ? ModelStatusReadFailure.accessDenied : .unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ModelStatusReadFailure.oversized }
        return data
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bounded(url, limit: 2_097_152)) as? [String: Any] else { throw ModelStatusReadFailure.invalidStatus }
        return value
    }
    static func digest(_ url: URL, limit: Int) throws -> String {
        try ordinary(url, limit: Int64(limit))
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == EACCES || errno == EPERM ? ModelStatusReadFailure.accessDenied : .unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_size <= Int64(limit), before.st_mode & S_IFMT == S_IFREG else { throw ModelStatusReadFailure.unsafeFile }
        var hash = SHA256(), readBytes = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            readBytes += chunk.count
            guard readBytes <= limit else { throw ModelStatusReadFailure.oversized }
            hash.update(data: chunk)
        }
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, Int64(readBytes) == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ModelStatusReadFailure.invalidStatus }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ root: URL, context: ModelValidationContext? = nil, onStage: ((String,String?) -> Void)? = nil) -> ModelStatusReadResult {
        // Every filesystem operation, including canonicalization and disk queries,
        // runs inside the service's utility queue, never on the main actor.
        do {
            onStage?("核对恢复目录",nil)
            guard root.isFileURL, !root.pathComponents.contains("sessions"), root.standardizedFileURL == root,
                  root.resolvingSymlinksInPath() == root else { throw ModelStatusReadFailure.invalidPath }
            onStage?("读取下载清单","download-manifest.json")
            let manifestData = try bounded(root.appendingPathComponent("download-manifest.json"), limit: 1_048_576)
            let manifest = try DownloadManifest.parse(manifestData, root: root)
            let context = context ?? ModelValidationContext.approved(for: root)
            guard context.accepts(manifest) else { throw ModelStatusReadFailure.invalidManifest }
            onStage?("读取下载状态","download-status.json")
            let statusData = try bounded(root.appendingPathComponent("download-status.json"), limit: 1_048_576)
            let snapshot: DownloadSnapshot
            do { snapshot = try DownloadSnapshot.parse(statusData, manifestTotal: manifest.total_bytes) }
            catch { throw ModelStatusReadFailure.invalidStatus }
            guard manifest.matches(snapshot) else { throw ModelStatusReadFailure.invalidStatus }
            onStage?("核对下载文件元数据",nil)
            let now = Date(), download = ModelPreparationVerifier.download(manifest, snapshot, root: root, now: now)
            onStage?("核对量化分片与注册","quantization-status.json")
            let quantization = ModelPreparationVerifier.quantization(manifest, snapshot, download: download, root: root, now: now)
            onStage?("核对运行时与管线契约","single-shot-native-app-contract-v2.json")
            let (runtime, authorized) = ModelPreparationVerifier.runtime(root: root, context: context, quantization: quantization)
            let verification = ModelPreparationVerification(download: download, quantization: quantization, runtime: runtime, checkedAt: now, nextGenerationAuthorized: authorized)
            var additional: Int64?
            onStage?("读取空间估算","local-audit.json")
            if let data = try? bounded(root.appendingPathComponent("local-audit.json"), limit: 2_097_152),
               let audit = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let plan = audit["conversion_plan"] as? [String: Any],
               let disk = plan["history_derived_disk_estimate"] as? [String: Any],
               let bytes = disk["additional_quantized_unique_allocated_bytes"] as? NSNumber, bytes.int64Value >= 0 { additional = bytes.int64Value }
            if quantization.state == .verified { additional = 0 }
            onStage?("读取磁盘可用空间",nil)
            let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            return .success(ModelStatusReadValue(snapshot: snapshot, freeBytes: capacity.map(Int64.init), quantizedAdditionalBytes: additional, verification: verification))
        } catch let failure as ModelStatusReadFailure { return .failure(failure) }
        catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && e.code == CocoaError.Code.fileReadNoPermission.rawValue
                || e.domain == NSPOSIXErrorDomain && [Int(EACCES),Int(EPERM)].contains(e.code) { return .failure(.accessDenied) }
            return .failure(.unavailable) // Do not surface paths or file contents.
        }
    }
}

final class ModelStatusReadService: @unchecked Sendable {
    static let shared = ModelStatusReadService()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.wengong.WanshenjiH3Studio.model-status", qos: .utility)
    private var busy = false
    private var accepted = 0
    private let reader: @Sendable (URL) -> ModelStatusReadResult
    private let trace: ModelReadTrace
    init(reader: (@Sendable (URL) -> ModelStatusReadResult)? = nil) {
        let trace = ModelReadTrace();self.trace = trace
        self.reader = reader ?? { ModelStatusReader.read($0,onStage:{ trace.step($0,$1) }) }
    }
    var currentRead: ModelReadObservation? { trace.snapshot }
    var acceptedReadCount: Int { lock.lock(); defer { lock.unlock() }; return accepted }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    @discardableResult func submit(_ root: URL, completion: @escaping @Sendable (ModelStatusReadResult) -> Void) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true; accepted += 1; lock.unlock()
        trace.begin()
        queue.async { [self] in
            let result = reader(root)
            trace.finish()
            lock.lock(); busy = false; lock.unlock()
            completion(result)
        }
        return true
    }
}
