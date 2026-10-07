import SwiftUI
import AppKit

struct H3FidelitySheet: View {
    @ObservedObject var store: TaskStore
    var jobID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var sample = 0
    @State private var observation = ""
    @State private var findings: [UUID:H3FidelityFinding] = [:]
    @State private var error: String?
    private var job: ShotJob? { store.state.jobs.first { $0.id == jobID } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text((job?.shortID ?? "") + " · 人脸保真对照").font(.title2)
                Spacer();Button("关闭") { dismiss() }
            }
            Text("先检查静态编解码损失，再检查运动生成漂移。1536输入直接来自完整原图。原模型8步对照沿用此前短段的原图、尺寸、种子和提示词，只移除Turbo加速适配并改为8步，用于检查加速方案是否加重失真，耗时会增加。只有此前运动漂移已留证才可开始；每种方案同图只运行一次，对照不能作为已接受端点。")
                .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                ForEach(H3FidelityKind.allCases) { kind in
                    Button(kind.title) { Task { await store.startFidelity(jobID,kind:kind) } }
                        .disabled(!store.canStartFidelity(jobID,kind:kind)).accessibilityIdentifier("fidelity." + kind.rawValue)
                }
                if store.fidelityJobID == jobID { Button("取消对照") { store.cancelFidelity(jobID) }.accessibilityIdentifier("fidelity.cancel") }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if let input = job?.h3Binding?.appFirstTask?.proposal.input {
                        HStack(alignment:.top) {
                            image(input.originalPath,title:"原始完整图",revision:input.originalSHA256)
                            image(input.normalizedPath,title:"当前 768 输入",revision:input.normalizedSHA256)
                            if let binding = job?.h3Binding { image(binding.outputDirectory + "/record/lossless-frames/frame-0000.png",title:"原候选 raw0",revision:binding.jobSHA256) }
                        }
                    }
                    ForEach(job?.h3FidelityChecks ?? []) { record in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(record.kind.title + " · 方案\(record.recipeVersion) · " + record.status).font(.headline)
                                Spacer()
                                Button("查看记录") { NSWorkspace.shared.open(URL(fileURLWithPath:record.directory)) }
                            }
                            Text(record.stage).font(.system(size:11)).textSelection(.enabled)
                            if let error = record.error { Text(error).font(.system(size:11)).foregroundStyle(.red).textSelection(.enabled) }
                            if record.status == "failed" { H3FidelityGuidanceCard(value:.executionFailure) }
                            if record.isActive,let progress = record.progress { Text("\(progress.completed) / \(progress.total) \(progress.unit)").font(.system(size:11,design:.monospaced)) }
                            if record.status == "completed" {
                                Picker("对照帧",selection:$sample) { Text("首帧 raw0").tag(0);Text("中间 raw10").tag(10);Text("末帧 raw21").tag(21) }.pickerStyle(.segmented)
                                HStack(alignment:.top) {
                                    image(record.inputPath,title:"本次实际输入",revision:record.requestSHA256)
                                    image(record.framePath(sample),title:record.kind.isMotion ? "本次原生 raw\(sample)" : "静态编解码 raw\(sample)",revision:record.reportSHA256 ?? "")
                                }
                                if let clip = record.clipPath { CandidateVideoPreview(path:clip,title:(job?.shortID ?? "") + " · " + record.kind.title).frame(height:220) }
                                if let note = record.observation {
                                    Text(note).font(.system(size:11)).textSelection(.enabled)
                                    if let guidance = record.guidance { H3FidelityGuidanceCard(value:guidance) }
                                }
                                else {
                                    Picker("实际检查结果",selection:Binding<H3FidelityFinding?>(get:{ findings[record.id] },set:{ findings[record.id] = $0 })) {
                                        Text("请选择已看到的差异").tag(nil as H3FidelityFinding?)
                                        ForEach(H3FidelityFinding.choices(for:record.kind)) { Text($0.title).tag(Optional($0)) }
                                    }.accessibilityIdentifier("fidelity.finding." + record.kind.rawValue)
                                    TextEditor(text:$observation).frame(height:70).accessibilityIdentifier("fidelity.observation." + record.kind.rawValue)
                                    Button("记录对照结论") {
                                        guard let finding = findings[record.id] else { return }
                                        do { try store.recordFidelityObservation(jobID,recordID:record.id,text:observation,finding:finding);observation = "";error = nil }
                                        catch { self.error = error.localizedDescription }
                                    }.disabled(observation.utf8.count < 12 || findings[record.id] == nil).accessibilityIdentifier("fidelity.record." + record.kind.rawValue)
                                }
                            }
                        }.padding(12).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:10))
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.system(size:11)) }
        }.padding(22).frame(width:920,height:720)
    }
    private func image(_ path: String,title: String,revision: String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:11,weight:.medium))
            AsyncPreviewImage(path:path,revision:revision,scope:.abReference,fit:true).frame(height:190)
            Button("查看原尺寸") { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }.font(.system(size:10))
        }.frame(maxWidth:.infinity)
    }
}
