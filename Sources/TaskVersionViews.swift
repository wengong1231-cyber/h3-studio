import SwiftUI

struct TaskVersionHistory: View {
    let group: TaskVersionGroup
    let selectedID: UUID
    let select: (UUID) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var playbackError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("此任务的全部版本 · \(group.versions.count)").font(.system(size: 12, weight: .semibold))
            Text("重做保留在同一任务内。每版的视频、拒绝原因和执行记录都可回看。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            ForEach(group.versions.reversed()) { version in
                VStack(alignment: .leading, spacing: 8) {
                    Button { select(version.id) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("第\(group.versionNumber(version.id))版" + (version.id == group.current.id ? " · 当前" : " · 历史"))
                                    .font(.system(size: 11, weight: .medium))
                                Text(version.displayStatusLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: selectedID == version.id ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundStyle(Color.studioGold)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("task-version.select.\(version.id.uuidString)")
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    if let rejection = version.h3VideoRejection {
                        Text("拒绝原因：" + rejection.reason).font(.system(size: 10)).foregroundStyle(Color.orange).textSelection(.enabled)
                    } else if let error = version.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(Color.orange).textSelection(.enabled)
                    }
                    if let path = version.candidate {
                        Button("放大播放第\(group.versionNumber(version.id))版", systemImage: "play.rectangle") {
                            do { try CandidatePlaybackController.shared.open(path: path, title: group.title + " · 第\(group.versionNumber(version.id))版") }
                            catch { playbackError = error.localizedDescription }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Text("执行记录 \(version.attempts.count) 次 · \(version.id.uuidString.prefix(8))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(10).background(Palette(scheme: scheme).raised.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let playbackError { Text(playbackError).font(.system(size: 10)).foregroundStyle(.red) }
        }
    }
}
