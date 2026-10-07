import Foundation
import Combine

struct DownloadFileStatus: Decodable, Identifiable, Sendable {
    var repo: String?
    var revision: String?
    var remote_path: String?
    var sha256: String?
    var git_blob_sha1: String?
    var publisher_checksum_verified: Bool?
    var relative_path: String
    var size: Int64
    var state: String
    var downloaded_bytes: Int64
    var id: String { relative_path }
    var name: String { URL(fileURLWithPath: relative_path).lastPathComponent }
    var label: String {
        switch state { case "verified": return "校验通过"; case "downloading": return "下载中（上报）"; default: return "等待下载" }
    }
}

struct DownloadSnapshot: Decodable, Sendable {
    var version: Int?
    var model_dir: String?
    var quantization_status: String?
    var quantization_status_file: String?
    var preparation_phase: String?
    var quantization_cli_exit_code: Int?
    var prepared_model_key: String?
    var prepared_model_root: String?
    var restoration_result_file: String?
    var status: String
    var updated_at: String
    var downloaded_bytes: Int64
    var expected_bytes: Int64
    var verified_files: Int
    var total_files: Int
    var quantization_still_required: Bool
    var generation_started: Bool
    var files: [DownloadFileStatus]
    var fraction: Double { Double(downloaded_bytes) / Double(max(1, expected_bytes)) }
    var date: Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: updated_at) ?? ISO8601DateFormatter().date(from: updated_at)
    }
    var isVerifiedTerminal: Bool { ["verified", "completed"].contains(status) }
    var isDownloading: Bool { ["running", "downloading"].contains(status) }
    // Completion records intentionally stop changing. Heartbeats only describe
    // ongoing downloads; completion still needs manifest and file verification.
    func stale(at now: Date = Date()) -> Bool {
        guard isDownloading else { return false }
        return date.map { now.timeIntervalSince($0) > 45 || $0.timeIntervalSince(now) > 45 } ?? true
    }
    static func parse(_ data: Data, manifestTotal: Int64?) throws -> DownloadSnapshot {
        guard data.count <= 1_048_576 else { throw StudioError.invalid("模型恢复状态过大，未读取。") }
        let snapshot = try JSONDecoder().decode(DownloadSnapshot.self, from: data)
        guard snapshot.expected_bytes > 0, snapshot.downloaded_bytes >= 0,
              snapshot.downloaded_bytes <= snapshot.expected_bytes, (1...100).contains(snapshot.total_files),
              (0...snapshot.total_files).contains(snapshot.verified_files), snapshot.files.count == snapshot.total_files,
              manifestTotal == nil || snapshot.expected_bytes == manifestTotal,
              snapshot.files.allSatisfy({ $0.size >= 0 && $0.downloaded_bytes >= 0 && $0.downloaded_bytes <= $0.size }) else {
            throw StudioError.invalid("模型字节计数与已核准清单不一致，保留缺值。")
        }
        return snapshot
    }
}

enum ModelStatusReadPhase: String { case idle, reading, waiting, timedOut, ready, unavailable, stopped }

@MainActor final class ModelReadinessMonitor: ObservableObject {
    nonisolated static let restoreRoot = AppIdentity.modelStatusRoot
    @Published private(set) var snapshot: DownloadSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var quantizedAdditionalBytes: Int64?
    @Published private(set) var verification: ModelPreparationVerification?
    @Published private(set) var refreshTime = Date()
    @Published private(set) var phase: ModelStatusReadPhase = .idle
    @Published private(set) var lastReadAt: Date?
    @Published private(set) var lastFailure: ModelStatusReadFailure?
    var currentRead: ModelReadObservation? { service.currentRead }
    private var timer: Timer?
    private var timeoutTimer: Timer?
    private var active = false
    private var generation = 0
    private var flight: UUID?
    private var flightStarted: Date?
    private var lastReadSucceeded = false
    // A short background refresh does not replace the last verified display.
    // Execution gates still use the actual phase and revalidate frozen inputs.
    var presentationPhase: ModelStatusReadPhase {
        if lastReadSucceeded, [.reading,.waiting].contains(phase),
           let started = flightStarted, Date().timeIntervalSince(started) < timeout { return .ready }
        return phase
    }
    private let service: ModelStatusReadService
    private let timeout: Double
    private let pollInterval: Double
    private let log: StartupPhaseLog?
    let root: URL
    var fraction: Double? { snapshot?.fraction }
    var hasConfirmedCurrentSnapshot: Bool {
        phase == .ready && verification?.download.state.isConfirmed == true && snapshot?.stale(at: refreshTime) == false
    }
    var currentQuantizationVerified: Bool { phase == .ready && verification?.quantization.state == .verified }
    var currentRuntimeVerified: Bool { phase == .ready && verification?.runtime.state == .verified }
    var downloadCheck: ModelStateDetail { current(verification?.download) }
    var quantizationCheck: ModelStateDetail { current(verification?.quantization) }
    var runtimeCheck: ModelStateDetail { current(verification?.runtime) }
    private func current(_ detail: ModelStateDetail?) -> ModelStateDetail {
        guard let detail else { return .unknown("尚未核对", "等待后台读取恢复状态") }
        guard presentationPhase == .ready else {
            return .unknown("当前读取未确认", "上次结果：" + detail.label + "；" + detail.note, verifiedAt: detail.verifiedAt)
        }
        if detail.state == .running, snapshot?.stale(at: refreshTime) == true {
            return .init(state: .stale, label: "下载心跳待更新", note: "进行中的下载超过 45 秒未上报；保留实际字节")
        }
        return detail
    }
    var reportLabel: String {
        switch presentationPhase {
        case .idle: return "模型恢复状态尚未读取"
        case .reading: return "正在读取恢复状态 · 当前状态未确认"
        case .waiting: return "等待前次读取 · 当前状态未确认"
        case .timedOut: return snapshot == nil ? "恢复状态读取超时 · 当前状态未知" : "恢复状态读取超时 · 保留上次快照"
        case .unavailable: return snapshot == nil ? "模型状态暂不可读" : "模型状态暂不可读 · 保留上次快照"
        case .stopped: return "状态读取已停止"
        case .ready: break
        }
        guard let snapshot else { return "模型恢复状态不可用" }
        if snapshot.stale(at: refreshTime) { return "下载心跳待更新" }
        if verification?.download.state == .verified {
            if verification?.quantization.state == .verified { return "模型下载与量化已核验" }
            return "模型下载已核验 · " + quantizationCheck.label
        }
        return downloadCheck.label
    }
    var remainingAfterPreparation: Int64? {
        guard let snapshot, let freeBytes, let quantizedAdditionalBytes else { return nil }
        return freeBytes - (snapshot.expected_bytes - snapshot.downloaded_bytes) - quantizedAdditionalBytes
    }
    var diskWarning: Bool { remainingAfterPreparation.map { $0 < 10 * 1_073_741_824 } ?? false }
    init(root: URL? = nil, service: ModelStatusReadService = .shared, timeout: Double = 8, pollInterval: Double = 5, log: StartupPhaseLog? = nil) {
        self.root = root ?? Self.restoreRoot; self.service = service; self.timeout = max(0.05, timeout); self.pollInterval = max(0.05, pollInterval); self.log = log
    }
    func start() {
        guard !active else { refresh(); return }
        active = true; generation += 1
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() {
        active = false; generation += 1
        timer?.invalidate(); timer = nil; timeoutTimer?.invalidate(); timeoutTimer = nil
        phase = .stopped; error = nil;lastFailure = nil; log?.record(.statusPollingStopped)
        // Keep the slot until the actual operation returns. Cancelling a task or
        // timing out does not cancel a blocked kernel open; never spawn another.
    }
    func refresh() {
        refreshTime = Date()
        guard active else { return }
        if flight != nil || service.isBusy {
            if flightStarted == nil { flightStarted = Date(); armTimeout() }
            if Date().timeIntervalSince(flightStarted!) >= timeout { markTimedOut() }
            else if phase != .timedOut && flight == nil { phase = .waiting }
            return
        }
        let id = UUID(), expectedGeneration = generation
        timeoutTimer?.invalidate(); timeoutTimer = nil
        flight = id; flightStarted = Date(); phase = .reading; error = nil;lastFailure = nil
        let accepted = service.submit(root) { [weak self] result in
            Task { @MainActor in self?.complete(id, generation: expectedGeneration, result: result) }
        }
        if accepted { log?.record(.statusReadStarted); armTimeout() }
        else { flight = nil; phase = .waiting; armTimeout() }
    }
    private func armTimeout() {
        guard timeoutTimer == nil else { return }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.flight != nil || self.service.isBusy else { return }
                self.markTimedOut()
            }
        }
    }
    private func markTimedOut() {
        guard phase != .timedOut else { return }
        phase = .timedOut; error = "读取尚未返回。界面和队列仍可操作；不据此判断模型就绪，也不叠加读取。"
        log?.record(.statusReadTimedOut)
    }
    private func complete(_ id: UUID, generation expected: Int, result: ModelStatusReadResult) {
        guard flight == id else { return }
        flight = nil; flightStarted = nil; timeoutTimer?.invalidate(); timeoutTimer = nil
        guard active else { return }
        guard generation == expected else { refresh(); return }
        refreshTime = Date(); lastReadAt = refreshTime
        switch result {
        case .success(let value):
            lastReadSucceeded = true
            snapshot = value.snapshot; freeBytes = value.freeBytes
            quantizedAdditionalBytes = value.quantizedAdditionalBytes
            verification = value.verification
            error = nil;lastFailure = nil; phase = .ready; log?.record(.statusReadCompleted)
        case .failure(let failure): lastReadSucceeded = false;error = failure.message;lastFailure = failure; phase = .unavailable; log?.record(.statusReadUnavailable)
        }
    }
    deinit { timer?.invalidate(); timeoutTimer?.invalidate() }
}

func formatGiB(_ bytes: Int64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }
func formatModelBytes(_ bytes: Int64) -> String {
    if bytes >= 1_073_741_824 { return formatGiB(bytes) }
    if bytes >= 1_048_576 { return String(format: "%.2f MiB", Double(bytes) / 1_048_576) }
    return String(format: "%.1f KiB", Double(bytes) / 1024)
}

enum VpipePhaseProgressParser {
    static func parse(_ line: String) -> EngineEvent? {
        let expression = #"\[PROGRESS\]\s+[0-9.]+% of '([^']+)' completed at [^\r\n]*\(([0-9]+)/([0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let stageRange = Range(match.range(at: 1), in: line),
              let doneRange = Range(match.range(at: 2), in: line),
              let totalRange = Range(match.range(at: 3), in: line),
              let done = Int(line[doneRange]), let total = Int(line[totalRange]), total > 0, done >= 0, done <= total else { return nil }
        // The unit is deliberately neutral: native denominators can change and
        // aren't necessarily the generation step count from the requested profile.
        return EngineEvent(type: "progress", stage: String(line[stageRange]), completed: done, total: total, unit: "阶段单位")
    }
}
