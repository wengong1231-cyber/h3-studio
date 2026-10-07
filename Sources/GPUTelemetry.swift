import Foundation
import IOKit

/// Device-wide driver counters. These never identify a process or allocate GPU work.
struct GPUReading: Codable, Identifiable {
    var timestamp = Date()
    var utilizationPercent: Double?
    var sharedSystemMemoryMB: Double?
    var deviceName: String?
    var unavailableReason: String?
    var source = "IORegistry · PerformanceStatistics"
    var scope = "whole_device_driver_reported"
    var id: Date { timestamp }
}

enum GPUStatisticsReader {
    static let utilizationKey = "Device Utilization %"
    static let memoryKey = "In use system memory"

    static func decode(statistics: [String: Any]?, deviceName: String?) -> GPUReading {
        var reading = GPUReading(deviceName: deviceName)
        func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        if let value = number(statistics?[utilizationKey]), (0...100).contains(value) {
            reading.utilizationPercent = value
        } else {
            reading.unavailableReason = statistics == nil ? "驱动未提供性能计数" : "驱动未提供有效的整机 GPU 使用率"
        }
        if let bytes = number(statistics?[memoryKey]), bytes >= 0 {
            reading.sharedSystemMemoryMB = bytes / 1_048_576
        }
        return reading
    }

    static func read() -> GPUReading {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS else {
            if iterator != 0 { IOObjectRelease(iterator) }
            return GPUReading(unavailableReason: "GPU 指标接口不可用（\(result)）")
        }
        defer { IOObjectRelease(iterator) }
        var readings: [GPUReading] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            // Read only these two properties on the accelerator itself. No client
            // entries, process names, recursive traversal or registry identifiers.
            let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            IOObjectRelease(service)
            readings.append(decode(statistics: statistics, deviceName: model))
        }
        guard readings.count == 1 else {
            return GPUReading(unavailableReason: readings.isEmpty ? "未找到可读取指标的 GPU" : "检测到多个 GPU，暂无可核实的整机汇总")
        }
        return readings[0]
    }
}
