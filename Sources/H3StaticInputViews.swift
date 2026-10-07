import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct H3StaticInputLibrarySheet: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var selectedAsset = ""
    @State private var references: Set<String> = []
    @State private var prompt = ""
    @State private var error: String?
    private var jobs: [ShotJob] { store.state.jobs.filter { $0.supersededBy == nil && $0.externalHistory == nil && $0.h3QueuePlan != nil && $0.h3Binding == nil && $0.attempts.isEmpty } }
    private var job: ShotJob? { jobs.first(where:{ $0.id.uuidString == target }) }
    private var assets: [H3StaticAsset] { store.staticAssets.filter { $0.shot == job?.shot } }
    private var primary: H3StaticAsset? { assets.first(where:{ $0.id == selectedAsset }) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:6) {
                    Text("完整图库与静态首图").font(.system(size:23,weight:.semibold))
                    Text("原图留档 → CPU 完整缩放 → 助手检查 → 串行 H3 候选").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer();Button("关闭") { dismiss() }.buttonStyle(.plain)
            }
            HStack {
                Label("\(store.staticAssets.count) 张已登记完整图",systemImage:"photo.stack").font(.system(size:11,weight:.medium))
                Spacer();Button("导入已知完整图集") { importCatalog(H3StaticCatalogReader.knownPath) }.buttonStyle(.bordered)
                Button("从交接文件导入…",action:chooseCatalog).buttonStyle(.bordered)
            }
            Picker("绑定镜头段",selection:$target) {
                Text("选择已登记镜头段").tag("")
                ForEach(jobs) { row in Text("\(row.shortID) · 第\(row.h3QueuePlan!.part)/\(row.h3QueuePlan!.partCount)段 · \(row.title)").tag(row.id.uuidString) }
            }.onChange(of:target) { _,_ in selectedAsset = "";references = [];prompt = "" }
            if let error { Text(error).font(.system(size:11)).foregroundStyle(Color.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if assets.isEmpty { Text("此镜号暂无完整图库。可以从交接清单导入，或在添加任务中选择已有完整图片。").font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,20) }
                    ForEach(assets) { asset in
                        HStack(alignment:.top,spacing:14) {
                            AsyncPreviewImage(path:asset.path,revision:asset.sha256,scope:.abReference,fit:true)
                                .frame(width:178,height:105).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:9))
                            VStack(alignment:.leading,spacing:7) {
                                Text(asset.stageLabel).font(.system(size:13,weight:.semibold))
                                Text("\(asset.width)×\(asset.height) · SHA " + String(asset.sha256.prefix(14))).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                                Text(asset.classification).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    Button(selectedAsset == asset.id ? "当前完整首图" : "用作完整首图") {
                                        selectedAsset = asset.id;references.remove(asset.id);prompt = asset.motionConstraints
                                    }.buttonStyle(.bordered).tint(selectedAsset == asset.id ? .studioGold : .secondary)
                                    if selectedAsset != asset.id {
                                        Toggle("动作/身份参考",isOn:Binding(get:{ references.contains(asset.id) },set:{ value in
                                            if value { references.insert(asset.id) } else { references.remove(asset.id) }
                                        })).toggleStyle(.checkbox).font(.system(size:10))
                                    }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.padding(12).background(Color.secondary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:12))
                    }
                    if job?.shot == 5 {
                        Label("河谷、土石切点、闭目、睁眼续段分别登记；睁眼图只作参考，续段使用已接受的闭目末帧。",systemImage:"list.number")
                            .font(.system(size:11)).foregroundStyle(Color.studioGold)
                        Button("同步 S05 阶段窗口…",action:chooseStageAllocation).buttonStyle(.bordered)
                    }
                    if job?.shot == 10 {
                        Label("静态图认可不等于视频通过；生成后仍须检查脸、手、弓、箭与太阳。命中终态不能用作起势。",systemImage:"exclamationmark.triangle")
                            .font(.system(size:11)).foregroundStyle(Color.studioGold)
                    }
                    if primary != nil {
                        Text("本次动作与约束").font(.system(size:11,weight:.semibold))
                        TextEditor(text:$prompt).font(.system(size:12)).frame(height:110).padding(6).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12)))
                        Text("动作参考不强制作为视频末帧。原图、旧检查与历史保留；本次原图和归一图需分别检查。").font(.system(size:10)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("按已登记窗口生成候选，保持并发 1。").font(.system(size:10)).foregroundStyle(.secondary)
                Spacer();Button("绑定完整图并准备") { bind() }.buttonStyle(StudioPrimaryButtonStyle())
                    .disabled((job.map { !store.canBindStaticInput($0.id) } ?? true) || primary == nil || prompt.utf8.count < 12 || references.count > 4)
            }
        }.padding(26).frame(width:740,height:680)
            .onAppear { target = jobs.first(where:{ $0.id == store.selectedID })?.id.uuidString ?? jobs.first?.id.uuidString ?? "" }
    }
    private func chooseCatalog() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json];panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK,let url = panel.url { importCatalog(url) } }
    }
    private func importCatalog(_ url: URL) { Task { do { _ = try await store.importStaticCatalog(url);error = nil } catch { self.error = error.localizedDescription } } }
    private func bind() {
        guard let job,let primary else { return }
        let selectedReferences = assets.filter { references.contains($0.id) }
        Task {
            do { _ = try await store.bindStaticInput(job.id,primary:primary,references:selectedReferences,prompt:prompt,
                sourceReference:"AppUI_material_selection:" + UUID().uuidString);error = nil;dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func chooseStageAllocation() {
        let panel = NSOpenPanel();panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK,let url = panel.url {
                Task {
                    do {
                        let allocation = try await Task.detached(priority:.utility) { try JSONDecoder().decode(H3StaticStageAllocation.self,from:H3Files.read(H3Files.safe(url.path),limit:262144)) }.value
                        try await store.bindStaticStageAllocation(allocation);error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct H3StaticBindingSummary: View {
    var binding: H3StaticInputBinding
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Label("完整静态图 · " + binding.primary.stageLabel,systemImage:"photo.badge.checkmark").font(.system(size:11,weight:.medium))
            Text("原图 SHA " + String(binding.primary.sha256.prefix(16))).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            Text(binding.primary.classification).font(.system(size:9)).foregroundStyle(.secondary)
            if !binding.motionReferences.isEmpty { Text("\(binding.motionReferences.count) 张身份/动作参考 · 不作为连续末帧锚点").font(.system(size:10)).foregroundStyle(Color.studioGold) }
            if !binding.hasRequiredPhaseAllocation { Text("S05 阶段窗口待同步，未启动生成。").font(.system(size:10)).foregroundStyle(Color.studioGold) }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.studioGold.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius:9))
    }
}
