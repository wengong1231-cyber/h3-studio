import Foundation
import SwiftUI
import AppKit

@MainActor enum TelemetrySelfTests {
    static func run(root: URL) -> Int32 {
        var checks: [StudioSelfTests.Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) throws {
            checks.append(.init(name: name, passed: passed, detail: detail))
            print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
            if !passed { throw StudioError.invalid(name) }
        }
        var live: [GPUReading] = [], durations: [Double] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let valid = GPUStatisticsReader.decode(statistics: ["Device Utilization %": 37.5, "In use system memory": 1_048_576], deviceName: "fixture")
            try check("驱动计数解析", valid.utilizationPercent == 37.5 && valid.sharedSystemMemoryMB == 1 && valid.deviceName == "fixture", "解析原始使用率与共享系统内存，单位正确")
            let zero = GPUStatisticsReader.decode(statistics: ["Device Utilization %": 0, "In use system memory": 0], deviceName: nil)
            try check("真实零值保留", zero.utilizationPercent == 0 && zero.sharedSystemMemoryMB == 0 && zero.unavailableReason == nil, "驱动明确上报零时，才显示零")
            let missing = GPUStatisticsReader.decode(statistics: nil, deviceName: nil)
            try check("缺失不填零", missing.utilizationPercent == nil && missing.sharedSystemMemoryMB == nil && missing.unavailableReason != nil, "接口缺失明确说明原因")
            let other = GPUStatisticsReader.decode(statistics: ["Renderer Utilization %": 99, "Tiler Utilization %": 95, "Alloc system memory": 2_097_152], deviceName: nil)
            try check("不替换指标口径", other.utilizationPercent == nil && other.sharedSystemMemoryMB == nil, "不把 renderer/tiler 或分配内存冒充设备使用率与实际使用内存")
            for (name, value) in [("负值", -1.0), ("超百分比", 101.0), ("NaN", Double.nan), ("无穷值", Double.infinity)] {
                let reading = GPUStatisticsReader.decode(statistics: ["Device Utilization %": value, "In use system memory": value], deviceName: nil)
                try check("无效使用率：" + name, reading.utilizationPercent == nil && reading.unavailableReason != nil, "缺值保留，拒绝无效数字")
            }
            let boolean = GPUStatisticsReader.decode(statistics: ["Device Utilization %": true, "In use system memory": true], deviceName: nil)
            try check("布尔值不当作计数", boolean.utilizationPercent == nil && boolean.sharedSystemMemoryMB == nil, "拒绝 CFBoolean")
            let strings = GPUStatisticsReader.decode(statistics: ["Device Utilization %": "42", "In use system memory": "1048576"], deviceName: nil)
            try check("字符串不猜数值", strings.utilizationPercent == nil && strings.sharedSystemMemoryMB == nil, "只接受驱动数值字段")
            let invalidMemory = GPUStatisticsReader.decode(statistics: ["Device Utilization %": 42, "In use system memory": -1], deviceName: nil)
            try check("使用率与内存独立缺值", invalidMemory.utilizationPercent == 42 && invalidMemory.sharedSystemMemoryMB == nil, "内存缺失不抹掉有效使用率")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let legacySample = Data("{\"timestamp\":0,\"cpuPercent\":12,\"pressure\":\"unknown\",\"samplingMilliseconds\":1}".utf8)
            let decoded = try JSONDecoder().decode(ResourceSample.self, from: legacySample)
            try check("旧资源记录兼容", decoded.gpu == nil && decoded.cpuPercent == 12, "0.4.4 未包含 GPU 的历史数据可读取")
            let legacyPeaks = Data("{\"systemCPU\":20,\"appFootprintMB\":30,\"workerRSSMB\":40,\"samples\":2}".utf8)
            var peaks = try JSONDecoder().decode(ResourcePeaks.self, from: legacyPeaks)
            try check("旧任务峰值兼容", peaks.systemGPU == nil && peaks.gpuSharedSystemMemoryMB == nil && peaks.samples == 2, "保留旧的 CPU/RSS 峰值")
            peaks.include(ResourceSample(gpu: valid, pressure: "fixture"))
            peaks.include(ResourceSample(gpu: missing, pressure: "fixture"))
            try check("缺值保留已有整机峰值", peaks.systemGPU == 37.5 && peaks.gpuSharedSystemMemoryMB == 1 && peaks.samples == 4, "缺值不会重置峰值")
            let roundTrip = try JSONDecoder().decode(ResourceSample.self, from: encoder.encode(ResourceSample(gpu: valid, pressure: "fixture")))
            try check("GPU 资源记录持久化", roundTrip.gpu?.utilizationPercent == 37.5 && roundTrip.gpu?.source == valid.source && roundTrip.gpu?.scope == "whole_device_driver_reported", "使用率、范围与来源可导出")
            var calls = 0
            let monitor = TelemetryMonitor(root: root, gpuReader: { calls += 1; return GPUReading(utilizationPercent: 42) })
            let first = monitor.sampleNow(), second = monitor.sampleNow()
            try check("快速重复采样不重复读 GPU", calls == 1 && first.gpu?.timestamp == second.gpu?.timestamp && second.gpu?.utilizationPercent == 42, "GPU 至少五秒读一次，保留原始计数时间")
            monitor.configure(enabled: true, interval: 2)
            monitor.configure(enabled: true, interval: 10)
            monitor.configure(enabled: false, interval: 10)
            monitor.configure(enabled: true, interval: 2)
            monitor.configure(enabled: false, interval: 2)
            try check("切换间隔和监控不突破 GPU 限频", calls == 1, "快速开关与重复配置复用缓存，保留计数的真实时间")
            var taskPeaks = ResourcePeaks()
            taskPeaks.include(ResourceSample(gpu: valid, pressure: "fixture"), gpuSince: valid.timestamp.addingTimeInterval(1))
            try check("任务开始前的 GPU 缓存不计入同期峰值", taskPeaks.systemGPU == nil && taskPeaks.gpuSharedSystemMemoryMB == nil, "任务起点以前的整机计数保持缺值")
            var one = valid; one.timestamp = Date(timeIntervalSince1970: 100)
            var gap = missing; gap.timestamp = Date(timeIntervalSince1970: 110)
            var two = zero; two.timestamp = Date(timeIntervalSince1970: 120)
            let points = GPUChartPoint.segments([one, one, gap, two])
            try check("曲线缺失处断开并去重", points.count == 2 && points[0].segment != points[1].segment && points[1].reading.utilizationPercent == 0, "缓存不产生重复点，缺值不插值，零值保留")
            // These calls only read accelerator counters. No Metal device, workload,
            // helper launch, per-process inspection or system permission request.
            for _ in 0..<3 {
                let begin = ProcessInfo.processInfo.systemUptime
                live.append(GPUStatisticsReader.read())
                durations.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
            }
            try check("本机 GPU 只读接口", live.allSatisfy { $0.utilizationPercent != nil || $0.unavailableReason != nil }, "有效计数或明确缺失，不以可用性预设造值")
            try check("采样可序列化", (try? encoder.encode(live)) != nil, "真实计数可序列化，不含 NaN/Infinity")
            try encoder.encode(live).write(to: root.appendingPathComponent("gpu-live-readings.json"), options: .atomic)
            let profile: [String: Any] = ["readOnly":true, "source":"IORegistry accelerator PerformanceStatistics", "scope":"whole device driver reported", "reads":durations.count, "milliseconds":durations, "meanMilliseconds":durations.reduce(0,+) / Double(durations.count), "gpuWorkloadStarted":false, "processClientsInspected":false]
            try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("gpu-read-profile.json"), options: .atomic)
        } catch {
            checks.append(.init(name: "异常", passed: false, detail: error.localizedDescription))
        }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to: root.appendingPathComponent("test-report.json"), options: .atomic) }
        return checks.contains(where: { !$0.passed }) ? 1 : 0
    }

    static func renderPreviews(root: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var records: [[String: Any]] = []
            let prefix = AppIdentity.version == "0.4.8" ? "first-shot" : AppIdentity.version == "0.4.7" ? "preview-fix" : AppIdentity.version == "0.4.6" ? "automation-fix" : "ui-gpu-fix"
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                for width in [302.0, 262.0] {
                    let bar = InspectorActionBar(
                        primary: InspectorAction(id: "generate", title: "开始生成 S41", icon: "play.fill", perform: {}),
                        secondary: [InspectorAction(id: "refresh", title: "核对更新配置", icon: "arrow.triangle.2.circlepath", perform: {}), InspectorAction(id: "cancel", title: "取消任务", icon: "stop.circle", perform: {})],
                        caption: "自动处理输入、校验、生成并检查输出。")
                    let view = VStack(alignment: .leading, spacing: 20) {
                        Text("S41 · 操作区预览").font(.system(size: 17, weight: .semibold))
                        bar
                    }.padding(20).frame(width: width).background(Palette(scheme: scheme).surface)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view); renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw StudioError.invalid("SwiftUI 离屏渲染不可用")
                    }
                    let name = "\(prefix)-layout-actions-\(Int(width))-\(suffix).png"
                    try data.write(to: root.appendingPathComponent(name), options: .atomic)
                    records.append(["file": name,"component":"InspectorActionBar", "widthPoints":width, "imagePixels":[image.width,image.height],"colorScheme":suffix])
                }
                let reading = GPUStatisticsReader.read()
                let card = GPUUsageView(readings: [reading], enabled: true, interval: 10)
                    .padding(20).frame(width: 720).background(Palette(scheme: scheme).background)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: card); renderer.scale = 2
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw StudioError.invalid("GPU 卡片离屏渲染不可用")
                }
                let name = "\(prefix)-layout-gpu-\(suffix).png"
                try data.write(to: root.appendingPathComponent(name), options: .atomic)
                records.append(["file":name,"component":"GPUUsageView","widthPoints":720,"imagePixels":[image.width,image.height],"colorScheme":suffix,"realReading":reading.utilizationPercent.map { $0 as Any } ?? NSNull()])
            }
            let report: [String: Any] = ["scope":"SwiftUI component offscreen renders; not desktop screenshots or formal CUA", "applicationLaunched":false,"taskStoreCreated":false,"generatorStarted":false,"records":records]
            try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("\(prefix)-layout-preview-report.json"), options:.atomic)
            print("Saved \(records.count) component renders; formal CUA pending.")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }
}
