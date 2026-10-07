import SwiftUI
import AppKit

struct H3VideoRejectionSheet: View {
    @ObservedObject var store: TaskStore
    var job: ShotJob
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Label("拒绝 " + job.shortID + " 候选",systemImage:"xmark.circle").font(.system(size:19,weight:.semibold))
                Spacer();Button("关闭") { dismiss() }.disabled(busy)
            }
            Text("保存拒绝原因，停止后续段采用这条视频。原候选、技术检查和原验收保留；重做会另建任务。")
                .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
            if let rejection = current?.h3VideoRejection {
                Text(rejection.reason).font(.system(size:12,weight:.medium))
                Text("来源：" + rejection.sourceReference + " · 操作者 " + rejection.actorKind).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("拒绝原因").font(.system(size:11,weight:.medium))
            TextEditor(text:$reason).font(.system(size:12)).frame(height:105).padding(8)
                .background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:9)).disabled(busy)
                .accessibilityIdentifier("rejection.reason")
            Text("此界面操作记录 UI 来源，操作者为未知。同步明确聊天拒绝时，会保留原始指令与实际候选 SHA。")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("同步外部用户拒绝") { importInstruction() }.disabled(busy || !store.canRejectVideo(job.id))
                    .accessibilityIdentifier("rejection.import")
                Spacer()
                Button(busy ? "正在保存" : "记录拒绝") { submit(source:nil) }
                    .buttonStyle(StudioPrimaryButtonStyle()).disabled(busy || !store.canRejectVideo(job.id) || reason.trimmingCharacters(in:.whitespacesAndNewlines).utf8.count < 8)
                    .accessibilityIdentifier("rejection.record")
            }
        }.padding(24).frame(width:520).onAppear { reason = current?.h3VideoRejection?.reason ?? "" }
    }
    private var current: ShotJob? { store.state.jobs.first(where:{ $0.id == job.id }) }
    private func importInstruction() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json]
        panel.begin { response in if response == .OK,let url = panel.url { submit(source:url) } }
    }
    private func submit(source: URL?) {
        guard !busy else { return };busy = true;error = nil
        Task { @MainActor in
            do { try await store.rejectVideo(job.id,reason:reason.trimmingCharacters(in:.whitespacesAndNewlines),source:source);busy = false;dismiss() }
            catch { self.error = error.localizedDescription;busy = false }
        }
    }
}
