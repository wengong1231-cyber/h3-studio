import SwiftUI
import Charts

struct GPUChartPoint: Identifiable {
    var reading: GPUReading
    var segment: Int
    var id: Date { reading.timestamp }
    static func segments(_ readings: [GPUReading]) -> [GPUChartPoint] {
        var seen = Set<Date>(), segment = 0, points: [GPUChartPoint] = []
        for reading in readings where seen.insert(reading.timestamp).inserted {
            guard reading.utilizationPercent != nil else { segment += 1; continue }
            points.append(GPUChartPoint(reading: reading, segment: segment))
        }
        return points
    }
}

struct GPUUsageView: View {
    var readings: [GPUReading]
    var enabled: Bool
    var interval: Double
    @Environment(\.colorScheme) private var scheme
    private var latest: GPUReading? { readings.last }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("整机 GPU", systemImage: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(latest?.deviceName ?? "设备指标").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(latest?.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(latest?.utilizationPercent == nil ? Color.secondary : Color.studioTeal)
                    Text("驱动上报使用率").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(formatMB(latest?.sharedSystemMemoryMB)).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("GPU 使用的共享系统内存").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if GPUChartPoint.segments(readings).isEmpty {
                Text(latest?.unavailableReason ?? "等待首次采样")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart(GPUChartPoint.segments(readings)) { point in
                    if let percent = point.reading.utilizationPercent {
                        AreaMark(x: .value("时间", point.reading.timestamp), y: .value("整机 GPU", percent), series: .value("连续有效采样", point.segment))
                            .foregroundStyle(LinearGradient(colors: [.studioTeal.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", point.reading.timestamp), y: .value("整机 GPU", percent), series: .value("连续有效采样", point.segment))
                            .foregroundStyle(Color.studioTeal).lineStyle(StrokeStyle(lineWidth: 1.8))
                        PointMark(x: .value("时间", point.reading.timestamp), y: .value("整机 GPU", percent))
                            .foregroundStyle(Color.studioTeal).symbolSize(12)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 135)
                .accessibilityLabel("整机 GPU 使用率历史；缺失采样处曲线断开")
            }
            HStack(alignment: .top) {
                Text(enabled ? "约 \(Int(max(5, interval))) 秒采样" : "监控已关闭 · 保留历史采样")
                Spacer()
                Text(latest.map { "更新于 " + $0.timestamp.formatted(date: .omitted, time: .standard) } ?? "暂无采样")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            Text(latest?.unavailableReason ?? "整机统计，包含其他应用；共享内存与系统内存共用，不是独立显存。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .padding(18).background(Palette(scheme: scheme).surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
