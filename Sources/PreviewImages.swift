import Foundation
import ImageIO
import CoreGraphics
import Combine
import Darwin

struct PreviewImageKey: Hashable, Sendable {
    var path: String
    var revision = ""
    var maxPixel = 512
    var pixelLimit: Int { min(1024,max(64,maxPixel)) }
}
enum PreviewScope: String, Codable, Sendable { case thumbnail, abReference, test }
enum PreviewImageFailure: String, Error, Codable, Sendable {
    case invalidPath, missing, notRegular, tooLarge, unreadable, decodeFailed, invalidDimensions, fileChanged, busy, timedOut, cancelled
    var message: String {
        switch self {
        case .timedOut: return "预览读取超时"
        case .busy: return "预览读取繁忙"
        case .cancelled: return "预览读取已取消"
        case .missing: return "预览文件不存在"
        case .decodeFailed,.invalidDimensions: return "图片预览无法解码"
        case .fileChanged: return "预览文件已变化"
        default: return "图片预览不可读"
        }
    }
}
final class PreviewBitmap: @unchecked Sendable {
    let image: CGImage
    let sourceBytes: Int
    var cost: Int { image.bytesPerRow * image.height }
    init(_ image: CGImage,sourceBytes: Int) { self.image = image;self.sourceBytes = sourceBytes }
}
struct PreviewFileIdentity: Equatable, Sendable {
    var device: Int32;var inode: UInt64;var size: Int64;var seconds: Int64;var nanoseconds: Int64
}
struct PreviewReadResult: Sendable {
    var result: Result<PreviewBitmap,PreviewImageFailure>
    var cacheHit = false
}
struct PreviewDiagnosticEntry: Codable, Sendable {
    var date = Date()
    var version = AppIdentity.version
    var requestID: UUID
    var scope: PreviewScope
    var phase: String
    var elapsedMilliseconds: Double?
    var cacheHit: Bool?
    var width: Int?
    var height: Int?
    var errorCode: String?
}
/// Best-effort bounded diagnostics. Never contains a path, prompt or native job ID.
final class PreviewDiagnostics: @unchecked Sendable {
    private static let queue = DispatchQueue(label:"com.wengong.WanshenjiH3Studio.preview-log",qos:.utility)
    private let lock = NSLock()
    private var pending = 0
    private let root: URL
    init(root: URL) { self.root = root }
    func record(_ entry: PreviewDiagnosticEntry) {
        lock.lock();guard pending < 48 else { lock.unlock();return };pending += 1;lock.unlock()
        Self.queue.async { [self] in
            defer { lock.lock();pending -= 1;lock.unlock() }
            do {
                let file = root.appendingPathComponent("preview-diagnostics.jsonl"),old = root.appendingPathComponent("preview-diagnostics.previous.jsonl")
                if (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 > 32_768 {
                    try? FileManager.default.removeItem(at:old)
                    try FileManager.default.moveItem(at:file,to:old)
                }
                if !FileManager.default.fileExists(atPath:file.path) { _ = FileManager.default.createFile(atPath:file.path,contents:nil) }
                let handle = try FileHandle(forWritingTo:file);defer { try? handle.close() }
                let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
                try handle.seekToEnd();try handle.write(contentsOf:encoder.encode(entry) + Data([10]))
            } catch { /* Optional diagnostics never prevent a preview. */ }
        }
    }
}
struct PreviewRequestToken: Sendable { var id: UUID;var key: PreviewImageKey }

/// Two actual operations at most; a timeout never frees a blocked kernel-read
/// slot. Cancelled queued operations are removed, and identical reads coalesce.
final class PreviewImageService: @unchecked Sendable {
    static let shared = PreviewImageService()
    struct Statistics { var cacheEntries: Int;var cacheBytes: Int;var flights: Int;var activeReads: Int;var peakActiveReads: Int;var cacheHits: Int;var decodes: Int }
    private struct Cached { var identity: PreviewFileIdentity;var bitmap: PreviewBitmap;var access: UInt64 }
    private struct Waiter { var began: Double;var scope: PreviewScope;var completion: (PreviewReadResult) -> Void }
    private final class Flight {
        var id = UUID();var operation: BlockOperation?;var waiters: [UUID:Waiter] = [:]
        var abandoned = false
    }
    private let lock = NSLock()
    private let queue = OperationQueue()
    private var cache: [PreviewImageKey:Cached] = [:]
    private var flights: [PreviewImageKey:Flight] = [:]
    private var access: UInt64 = 0,cacheBytes = 0,activeReads = 0,peakActiveReads = 0,cacheHits = 0,decodes = 0
    private var diagnostics: PreviewDiagnostics?
    let cacheByteLimit: Int,cacheEntryLimit: Int,flightLimit: Int,timeout: Double
    private let beforeRead: (() -> Void)?
    init(cacheByteLimit: Int = 24 * 1_048_576,cacheEntryLimit: Int = 32,flightLimit: Int = 24,timeout: Double = 3,beforeRead: (() -> Void)? = nil) {
        self.cacheByteLimit = max(1,cacheByteLimit);self.cacheEntryLimit = max(1,cacheEntryLimit)
        self.flightLimit = max(2,flightLimit);self.timeout = max(0.05,timeout);self.beforeRead = beforeRead
        queue.name = "com.wengong.WanshenjiH3Studio.preview-read";queue.qualityOfService = .utility;queue.maxConcurrentOperationCount = 2
    }
    func configureDiagnostics(root: URL) { lock.lock();diagnostics = PreviewDiagnostics(root:root);lock.unlock() }
    func record(_ entry: PreviewDiagnosticEntry) { lock.lock();let sink = diagnostics;lock.unlock();sink?.record(entry) }
    func statistics() -> Statistics { lock.lock();defer { lock.unlock() };return .init(cacheEntries:cache.count,cacheBytes:cacheBytes,flights:flights.count,activeReads:activeReads,peakActiveReads:peakActiveReads,cacheHits:cacheHits,decodes:decodes) }
    @discardableResult func request(_ key: PreviewImageKey,scope: PreviewScope,requestID: UUID = UUID(),completion: @escaping (PreviewReadResult) -> Void) -> PreviewRequestToken {
        let token = PreviewRequestToken(id:requestID,key:key),began = ProcessInfo.processInfo.systemUptime
        record(.init(requestID:token.id,scope:scope,phase:"requested",elapsedMilliseconds:0))
        lock.lock()
        let flight: Flight
        if let existing = flights[key],!existing.abandoned || existing.operation?.isExecuting == true { flight = existing }
        else {
            if let previous = flights[key],previous.waiters.isEmpty { flights.removeValue(forKey:key) }
            guard flights.count < flightLimit else {
                lock.unlock();deliver(.init(result:.failure(.busy)),id:token.id,waiter:.init(began:began,scope:scope,completion:completion));return token
            }
            flight = Flight();flights[key] = flight
        }
        guard flight.waiters.count < 64 else { lock.unlock();deliver(.init(result:.failure(.busy)),id:token.id,waiter:.init(began:began,scope:scope,completion:completion));return token }
        flight.waiters[token.id] = .init(began:began,scope:scope,completion:completion)
        let shouldStart = flight.operation == nil,flightID = flight.id
        if shouldStart {
            let operation = BlockOperation { [weak self] in self?.read(key,flightID:flightID) }
            operation.completionBlock = { [weak self] in self?.finish(key,flightID:flightID,result:.init(result:.failure(.cancelled))) }
            flight.operation = operation
        }
        let operation = flight.operation;lock.unlock()
        if shouldStart,let operation { queue.addOperation(operation) }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout) { [weak self] in self?.expire(token) }
        return token
    }
    func cancel(_ token: PreviewRequestToken) { removeWaiter(token,reason:.cancelled) }
    private func expire(_ token: PreviewRequestToken) { removeWaiter(token,reason:.timedOut) }
    private func removeWaiter(_ token: PreviewRequestToken,reason: PreviewImageFailure) {
        lock.lock()
        guard let flight = flights[token.key],let waiter = flight.waiters.removeValue(forKey:token.id) else { lock.unlock();return }
        let operation = flight.waiters.isEmpty ? flight.operation : nil
        if flight.waiters.isEmpty { flight.abandoned = true }
        lock.unlock();operation?.cancel();deliver(.init(result:.failure(reason)),id:token.id,waiter:waiter)
    }
    private func deliver(_ value: PreviewReadResult,id: UUID,waiter: Waiter) {
        var entry = PreviewDiagnosticEntry(requestID:id,scope:waiter.scope,phase:"finished",elapsedMilliseconds:max(0,(ProcessInfo.processInfo.systemUptime-waiter.began)*1000),cacheHit:value.cacheHit)
        switch value.result {
        case .success(let bitmap): entry.width = bitmap.image.width;entry.height = bitmap.image.height
        case .failure(let error): entry.errorCode = error.rawValue;entry.phase = error == .cancelled ? "cancelled" : error == .timedOut ? "timedOut" : "failed"
        }
        record(entry);DispatchQueue.main.async { waiter.completion(value) }
    }
    private func finish(_ key: PreviewImageKey,flightID: UUID,result: PreviewReadResult) {
        lock.lock();guard let flight = flights[key],flight.id == flightID else { lock.unlock();return }
        flights.removeValue(forKey:key);let waiters = flight.waiters;lock.unlock()
        for (id,waiter) in waiters { deliver(result,id:id,waiter:waiter) }
    }
    private func identity(_ key: PreviewImageKey) throws -> PreviewFileIdentity {
        let url = URL(fileURLWithPath:key.path).standardizedFileURL
        guard key.path.hasPrefix("/"),url.path == key.path,!url.pathComponents.contains("sessions"),url.resolvingSymlinksInPath().path == key.path else { throw PreviewImageFailure.invalidPath }
        var values = stat()
        guard key.path.withCString({ Darwin.lstat($0,&values) }) == 0 else { throw errno == ENOENT ? PreviewImageFailure.missing : PreviewImageFailure.unreadable }
        guard (values.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw PreviewImageFailure.notRegular }
        guard values.st_size > 0,values.st_size <= 50_331_648 else { throw PreviewImageFailure.tooLarge }
        return .init(device:values.st_dev,inode:values.st_ino,size:values.st_size,seconds:Int64(values.st_mtimespec.tv_sec),nanoseconds:Int64(values.st_mtimespec.tv_nsec))
    }
    private func read(_ key: PreviewImageKey,flightID: UUID) {
        lock.lock();guard let flight = flights[key],flight.id == flightID,!flight.waiters.isEmpty else { lock.unlock();return }
        activeReads += 1;peakActiveReads = max(peakActiveReads,activeReads);let startedWaiters = flight.waiters;lock.unlock()
        defer { lock.lock();activeReads -= 1;lock.unlock() }
        for (id,waiter) in startedWaiters { record(.init(requestID:id,scope:waiter.scope,phase:"readStarted",elapsedMilliseconds:max(0,(ProcessInfo.processInfo.systemUptime-waiter.began)*1000))) }
        beforeRead?()
        guard hasSubscribers(key,flightID:flightID) else { finish(key,flightID:flightID,result:.init(result:.failure(.cancelled)));return }
        let output: PreviewReadResult
        do {
            let current = try identity(key)
            lock.lock();access &+= 1
            if var existing = cache[key],existing.identity == current {
                existing.access = access;cache[key] = existing;cacheHits += 1;lock.unlock()
                finish(key,flightID:flightID,result:.init(result:.success(existing.bitmap),cacheHit:true));return
            }
            if let previous = cache.removeValue(forKey:key) { cacheBytes -= previous.bitmap.cost }
            lock.unlock()
            let data: Data
            do { data = try Data(contentsOf:URL(fileURLWithPath:key.path)) } catch { throw PreviewImageFailure.unreadable }
            guard hasSubscribers(key,flightID:flightID) else { throw PreviewImageFailure.cancelled }
            guard data.count == current.size,try identity(key) == current else { throw PreviewImageFailure.fileChanged }
            guard let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0,height > 0,width <= 32_768,height <= 32_768,Int64(width)*Int64(height) <= 67_108_864 else { throw PreviewImageFailure.invalidDimensions }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:key.pixelLimit,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw PreviewImageFailure.decodeFailed }
            guard max(image.width,image.height) <= key.pixelLimit,try identity(key) == current else { throw PreviewImageFailure.fileChanged }
            let bitmap = PreviewBitmap(image,sourceBytes:data.count)
            lock.lock();decodes += 1;access &+= 1
            if bitmap.cost <= cacheByteLimit {
                cache[key] = Cached(identity:current,bitmap:bitmap,access:access);cacheBytes += bitmap.cost
                while cache.count > cacheEntryLimit || cacheBytes > cacheByteLimit {
                    guard let victim = cache.min(by:{ $0.value.access < $1.value.access })?.key,let removed = cache.removeValue(forKey:victim) else { break };cacheBytes -= removed.bitmap.cost
                }
            }
            lock.unlock();output = .init(result:.success(bitmap))
        } catch let error as PreviewImageFailure { output = .init(result:.failure(error)) }
        catch { output = .init(result:.failure(.unreadable)) }
        finish(key,flightID:flightID,result:output)
    }
    private func hasSubscribers(_ key: PreviewImageKey,flightID: UUID) -> Bool {
        lock.lock();defer { lock.unlock() };return flights[key]?.id == flightID && flights[key]?.waiters.isEmpty == false
    }
}

@MainActor final class PreviewImageModel: ObservableObject {
    @Published private(set) var bitmap: PreviewBitmap?
    @Published private(set) var failure: PreviewImageFailure?
    private(set) var key: PreviewImageKey?
    private(set) var appliedCount = 0,discardedCount = 0
    private var generation = UUID()
    private var token: PreviewRequestToken?
    private var service: PreviewImageService?
    func begin(_ key: PreviewImageKey,scope: PreviewScope,service: PreviewImageService = .shared) {
        cancel();self.key = key;self.service = service;let expected = generation
        token = service.request(key,scope:scope,requestID:expected) { [weak self] result in
            guard let self else { return }
            guard self.generation == expected,self.key == key else {
                self.discardedCount += 1
                service.record(.init(requestID:expected,scope:scope,phase:"discardedStale",elapsedMilliseconds:nil));return
            }
            self.token = nil
            switch result.result {
            case .success(let bitmap): self.bitmap = bitmap;self.failure = nil;self.appliedCount += 1
            case .failure(let error): self.bitmap = nil;self.failure = error
            }
        }
    }
    func cancel() {
        generation = UUID()
        if let token { service?.cancel(token) };token = nil;bitmap = nil;failure = nil;key = nil
    }
}
