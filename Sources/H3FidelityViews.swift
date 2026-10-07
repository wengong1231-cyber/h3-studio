import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            Text("首尾同图对照仅在8步仍有身份漂移并留证后开放：沿用同图、同Prompt、同种子和8步，只将同一原图也接入末帧。它是22帧约束试验，不是完整碰撞动作，也不是持续身份锁；中间帧仍须检查。")
                .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack(alignment:.top) {
                if let job,let engine = job.h3ReferenceEngine {
                    Text("隔离 Vpipe " + engine.manifest.version + " 已登记 · " + H3ReferenceEngine.trialStatus(job) + "。参考模式会把原图编码进模型；它是零样本能力，不固定首帧，也不保证同脸。每次仍需检查22帧样本。")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("fidelity.trial-status")
                    if job.h3ReferenceTrialPolicy == nil {
                        Button("更新试验次数设置") { chooseTrialPolicy() }
                            .disabled(!store.singleGeneratorIdle).accessibilityIdentifier("fidelity.import-trial-policy")
                    }
                    if let proposal = job.h3Binding?.appFirstTask?.proposal {
                        Button("复制参考对照Prompt") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(H3ReferenceEngine.prompt(proposal),forType:.string) }
                        Button("复制首帧基线Prompt") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(proposal.prompt,forType:.string) }
                    }
                } else {
                    Button("登记已授权隔离引擎") { chooseReferenceEngine() }
                        .disabled(!store.singleGeneratorIdle || job?.shot != 26).accessibilityIdentifier("fidelity.register-engine")
                    Text("导入固定版本及明确授权；先核官方签名、现有视觉权重，再开放参考对照。登记不启动GPU。")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
            if job?.h3ReferenceEngine != nil {
                Text("新版单首帧基线与旧引擎原模型8步对照保持相同图像、种子、原Prompt及单首帧管线，仅切换已登记引擎。先完成参考模式的实际检查才开放；用来区分引擎与参考条件的影响，不是已验证修复。历史试验始终保留，新方案仍须有可验证的条件变化。")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.leading),count:3),alignment:.leading) {
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
                                    if let job,let guidance = record.guidanceForDisplay(in:job) { H3FidelityGuidanceCard(value:guidance) }
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
    private func chooseTrialPolicy() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK,let url = panel.url {
                Task { do { try await store.importReferenceTrialPolicy(url,jobID:jobID);error = nil } catch { self.error = error.localizedDescription } }
            }
        }
    }
    private func chooseReferenceEngine() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK,let url = panel.url {
                Task { do { try await store.registerReferenceEngine(url,jobID:jobID);error = nil } catch { self.error = error.localizedDescription } }
            }
        }
    }
    private func image(_ path: String,title: String,revision: String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:11,weight:.medium))
            AsyncPreviewImage(path:path,revision:revision,scope:.abReference,fit:true).frame(height:190)
            Button("查看原尺寸") { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }.font(.system(size:10))
        }.frame(maxWidth:.infinity)
    }
}
