import SwiftUI

struct ModelDownloadBar: View {
    @ObservedObject var monitor: ModelReadinessMonitor
    var expand: () -> Void
    var body: some View {
        Button(action: expand) {
            VStack(spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Color.studioGold)
                    Text(monitor.reportLabel).font(.system(size: 10, weight: .medium))
                    if let snapshot = monitor.snapshot {
                        Spacer()
                        Text(formatGiB(snapshot.downloaded_bytes) + " / " + formatGiB(snapshot.expected_bytes))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text(String(format: "%.2f%%", snapshot.fraction * 100)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.studioGold)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                if let fraction = monitor.fraction { ProgressView(value: fraction).tint(.studioGold) }
            }.padding(.horizontal, 24).padding(.vertical, 12).background(Color.studioGold.opacity(0.045))
        }.buttonStyle(.plain).help("查看恢复任务的实际字节进度、更新时间与磁盘空间估算")
    }
}

struct ModelPreparationView: View {
    @ObservedObject var monitor: ModelReadinessMonitor
    @ObservedObject var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("MiniMax H3 FL2VA · 8-bit / Turbo LoRA v4", systemImage: "shippingbox").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("只读状态").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    stateTile("01 · 原文件下载", "arrow.down.circle", monitor.downloadCheck)
                    stateTile("02 · 量化与注册", "shippingbox", monitor.quantizationCheck)
                    stateTile("03 · 本地运行时", "cpu", monitor.runtimeCheck)
                    stateTile("04 · 镜头任务绑定", "link", ModelTaskBindingSummary.detail(jobs: store.state.jobs, selectedID: store.selectedID))
                }
                if let snapshot = monitor.snapshot {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("原文件下载字节 · " + monitor.reportLabel).font(.system(size: 13, weight: .medium))
                                Text(formatGiB(snapshot.downloaded_bytes) + " / " + formatGiB(snapshot.expected_bytes))
                                    .font(.system(size: 25, weight: .medium, design: .rounded))
                            }
                            Spacer()
                            Text(String(format: "%.2f%%", snapshot.fraction * 100)).font(.system(size: 27, weight: .light, design: .rounded)).foregroundStyle(Color.studioGold)
                        }
                        ProgressView(value: snapshot.fraction).tint(.studioGold)
                        HStack {
                            Text("\(snapshot.verified_files) / \(snapshot.total_files) 个文件校验通过")
                            Spacer()
                            Text((snapshot.isVerifiedTerminal ? "完成记录：" : "来源更新：") + (snapshot.date?.formatted(date: .abbreviated, time: .standard) ?? "未知"))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        if !monitor.hasConfirmedCurrentSnapshot {
                            Text(snapshot.stale(at: monitor.refreshTime) ? "进行中的下载超过 45 秒未上报心跳；保留最近实际字节，当前下载进程状态未确认。" : "显示最近实际字节快照；当前文件或读取核对未通过，不能据此判断模型可执行。")
                                .font(.system(size: 10)).foregroundStyle(Color.studioGold)
                        }
                    }.padding(20).background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 12) {
                        tile("磁盘可用", monitor.freeBytes.map(formatGiB) ?? "不可用", "恢复目录所在卷，当前读取")
                        tile("转换额外空间", monitor.quantizedAdditionalBytes.map(formatGiB) ?? "待核准", monitor.currentQuantizationVerified ? "转换已完成 · 不重复扣除空间" : "历史估计 · 同卷硬链接前提")
                        tile(monitor.currentQuantizationVerified ? "当前准备完成后余量" : "准备后余量估计", monitor.remainingAfterPreparation.map(formatGiB) ?? "不可用", monitor.currentQuantizationVerified ? "当前磁盘实测 · 未预留新生成" : "当前余量 − 剩余下载 − 转换")
                    }
                    if monitor.diskWarning { Label("预计准备后余量不足 10 GiB，请由恢复任务协调空间。应用不会启动转换。", systemImage: "externaldrive.badge.exclamationmark").font(.system(size: 11)).foregroundStyle(Color.studioGold) }
                    VStack(spacing: 0) {
                        ForEach(snapshot.files) { file in
                            HStack(spacing: 12) {
                                Image(systemName: file.state == "verified" ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(file.state == "verified" ? Color.studioTeal : Color.studioGold)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(file.label).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatModelBytes(file.downloaded_bytes) + " / " + formatModelBytes(file.size)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }.padding(13)
                            if file.id != snapshot.files.last?.id { Divider().opacity(0.4) }
                        }
                    }.background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("完成终态不要求持续心跳，保留来源的验证时间。下载、量化、运行时文件通过核对后，镜头仍需绑定新的已授权单镜并逐镜确认。真实生成不会自动开始。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("每 5 秒在后台只读核对。百分比仅为实际下载字节 / 清单总字节；完整权重校验沿用恢复任务记录，当前重新核对文件存在、大小、配置、索引及注册指纹。运行时核对不代表模型已加载或新视频已验收。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
                } else {
                    Label(monitor.reportLabel, systemImage: "link").font(.system(size: 17)).foregroundStyle(.secondary).padding(.vertical, 30)
                }
                if let checkedAt = monitor.lastReadAt {
                    Text("本次读取：" + checkedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let error = monitor.error { Text(error).font(.system(size: 10)).foregroundStyle(Color.studioGold).textSelection(.enabled) }
            }
        }
    }
    private func stateTile(_ title: String, _ symbol: String, _ detail: ModelStateDetail) -> some View {
        let color: Color = detail.state == .verified ? .studioTeal : ([.failed, .mismatch].contains(detail.state) ? .red.opacity(0.85) : .studioGold)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: detail.state == .verified ? "checkmark.circle.fill" : ([.failed, .mismatch].contains(detail.state) ? "exclamationmark.circle" : "clock"))
                    .foregroundStyle(color).accessibilityHidden(true)
            }
            Text(detail.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(detail.note).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let date = detail.verifiedAt {
                Text("来源验证：" + date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            .background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
    private func tile(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(Palette(scheme: scheme).surface).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
