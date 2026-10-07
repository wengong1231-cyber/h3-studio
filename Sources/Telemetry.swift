import Foundation
import Combine
import Darwin

struct ResourceSample: Codable, Identifiable {
    var timestamp = Date()
    var cpuPercent: Double?
    var gpu: GPUReading?
    var appFootprintMB: Double?
    var workerRSSMB: Double?
    var systemUsedMB: Double?
    var systemTotalMB: Double?
    var diskFreeGB: Double?
    var pressure: String
    var samplingMilliseconds: Double = 0
    var id: Date { timestamp }
}

@MainActor final class TelemetryMonitor: ObservableObject {
    @Published var samples: [ResourceSample] = []
    @Published var enabled = true
    @Published var interval: Double = 5
    @Published var pressure = "暂无压力事件"
    var ownedPIDs: () -> [Int32] = { [] }
    var onSample: ((ResourceSample) -> Void)?
    var onCriticalPressure: (() -> Void)?
    private var timer: Timer?
    private var previousTicks: [UInt32]?
    private var lastGPUReading: GPUReading?
    private var lastGPUReadUptime: Double?
    private let gpuReader: () -> GPUReading
    private var pressureSource: DispatchSourceMemoryPressure?
    let root: URL
    var latest: ResourceSample? { samples.last }
    var averageSamplingMilliseconds: Double { samples.isEmpty ? 0 : samples.map(\.samplingMilliseconds).reduce(0, +) / Double(samples.count) }

    init(root: URL, gpuReader: @escaping () -> GPUReading = GPUStatisticsReader.read) {
        self.root = root; self.gpuReader = gpuReader
    }
    func configure(enabled: Bool, interval: Double) {
        timer?.invalidate(); timer = nil
        pressureSource?.cancel(); pressureSource = nil
        self.enabled = enabled; self.interval = max(2, interval)
        previousTicks = nil
        guard enabled else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let flags = source?.data else { return }
            if flags.contains(.critical) { self.pressure = "严重"; self.onCriticalPressure?() }
            else if flags.contains(.warning) { self.pressure = "警告" }
            else { self.pressure = "正常" }
        }
        source.resume(); pressureSource = source
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
    }

    @discardableResult func sampleNow() -> ResourceSample {
        let begin = ProcessInfo.processInfo.systemUptime
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var sample = ResourceSample(pressure: pressure)
        // GPU counters have their own timestamp and are read at most every five
        // seconds. H3 keeps the existing minimum ten-second telemetry interval.
        if lastGPUReadUptime == nil || begin - lastGPUReadUptime! >= 5 {
            lastGPUReading = gpuReader()
            lastGPUReadUptime = begin
        }
        sample.gpu = lastGPUReading
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let previousTicks {
                let changes = zip(ticks, previousTicks).map { UInt64($0 &- $1) }
                let total = changes.reduce(0, +)
                if total > 0 { sample.cpuPercent = 100 * Double(total - changes[Int(CPU_STATE_IDLE)]) / Double(total) }
            }
            previousTicks = ticks
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS { sample.appFootprintMB = Double(vm.phys_footprint) / 1_048_576 }
        let pids = ownedPIDs().filter { $0 > 0 && $0 != getpid() }
        if !pids.isEmpty {
            var total: UInt64 = 0, received = 0
            for pid in pids {
                var info = proc_taskinfo()
                let bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                if bytes == MemoryLayout<proc_taskinfo>.size { total += info.pti_resident_size; received += 1 }
            }
            // Missing process readings remain missing, rather than being reported as zero.
            if received == pids.count { sample.workerRSSMB = Double(total) / 1_048_576 }
        }
        var memory = vm_statistics64_data_t()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount)
            }
        }
        var pageSize: vm_size_t = 0
        if memoryResult == KERN_SUCCESS && host_page_size(host, &pageSize) == KERN_SUCCESS {
            let pages = UInt64(memory.active_count) + UInt64(memory.inactive_count) + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)
            sample.systemUsedMB = Double(pages * UInt64(pageSize)) / 1_048_576
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        if totalBytes > 0 { sample.systemTotalMB = Double(totalBytes) / 1_048_576 }
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let capacity = values.volumeAvailableCapacity {
            sample.diskFreeGB = Double(capacity) / 1_073_741_824
        }
        sample.samplingMilliseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        samples.append(sample)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        onSample?(sample)
        return sample
    }
}
