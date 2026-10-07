import SwiftUI
import AppKit

struct H3ABReferences: View {
    var configuration: H3ABConfiguration
    var preparation: H3InputPreparation?
    var terminal = false
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            reference(configuration.first,role:"A",title:"A · 水下首帧")
            reference(configuration.last,role:"B",title:"B · 海上末帧")
        }
    }
    private func reference(_ input: H3ABInput,role: String,title: String) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.system(size:10,weight:.medium))
            image(input.originalPath,revision:input.originalSHA256 ?? "",placeholder:"等待原图").accessibilityLabel(title + "，处理前原图")
            Text("处理前 · 原图").font(.system(size:9)).foregroundStyle(.secondary)
            image(input.normalizedSHA256 == nil ? preparation?.images.first(where:{ $0.role == role })?.path : input.normalizedPath,revision:input.normalizedSHA256 ?? configuration.sourceSHA256,placeholder:"尚未处理").accessibilityLabel(title + "，处理后 768 乘 448 预览")
            Text("处理后 · 768×448").font(.system(size:9)).foregroundStyle(.secondary)
            Label(input.automaticallyValidated ? "自动输入检查通过" : terminal ? "归一图记录" : "开始后自动校验",systemImage:input.automaticallyValidated ? "checkmark.circle" : "arrow.triangle.2.circlepath").font(.system(size:9)).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).accessibilityElement(children:.contain)
    }
    private func image(_ path: String?,revision: String,placeholder: String) -> some View {
        VStack(alignment:.leading,spacing:7) {
            ZStack {
                RoundedRectangle(cornerRadius:9).fill(Color.secondary.opacity(0.06))
                if let path {
                    AsyncPreviewImage(path:path,revision:revision,scope:.abReference,fit:true).padding(4)
                } else {
                    VStack(spacing:7) { Image(systemName:"photo").font(.system(size:19,weight:.light));Text(placeholder).font(.system(size:9)) }.foregroundStyle(.secondary)
                }
            }.frame(height:90)
        }
    }
}

struct H3ABTaskTimeline: View {
    var job: ShotJob
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("任务步骤").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            if let preparation = job.h3InputPreparation {
                step("素材检查",status:"completed",start:preparation.materialsStartedAt,end:preparation.materialsEndedAt,detail:"A/B 指纹与尺寸已核对")
                step("图片预处理",status:preparation.status,start:preparation.startedAt,end:preparation.endedAt,detail:"\(preparation.images.count) / 2 张实际写出 · CPU")
                step("输入自动检查",status:preparation.automaticValidationStatus ?? "waiting",start:preparation.automaticValidationStartedAt,end:preparation.automaticValidationEndedAt,detail:"完整解码、768×448、指纹与 A/B 绑定")
            }
            step("视频生成",status:job.h3GenerationStartedAt == nil ? "waiting" : job.h3GenerationEndedAt == nil ? "running" : job.h3ValidationStartedAt != nil ? "completed" : job.status.rawValue,start:job.h3GenerationStartedAt,end:job.h3GenerationEndedAt,detail:job.h3GenerationStartedAt == nil ? "尚未进入 GPU" : job.h3Outcome?.simulated == true || job.parameters.model.contains("CPU") ? "CPU 合成验证 · 非实际 H3" : "本条 H3 · 原生 73 帧")
            step("输出检查",status:job.h3ValidationStartedAt == nil ? "waiting" : job.h3ValidationEndedAt == nil ? "running" : job.h3Outcome?.technicalPass == true ? "completed" : job.status.rawValue,start:job.h3ValidationStartedAt,end:job.h3ValidationEndedAt,detail:job.h3Outcome?.technicalPass == true ? "自动技术检查通过 · 候选已保存" : "73 帧、完整音视频与逐帧图片")
        }
    }
    private func step(_ name: String,status: String,start: Date?,end: Date?,detail: String) -> some View {
        let labels = ["waiting":"未开始","running":"处理中","completed":"已完成","failed":"失败","cancelled":"已取消","interrupted":"已中断","blocked":"未开始"]
        return VStack(alignment:.leading,spacing:5) {
            HStack {
                Image(systemName:status == "completed" ? "checkmark.circle.fill" : status == "running" ? "circle.dotted" : ["failed","interrupted"].contains(status) ? "exclamationmark.circle" : "circle").foregroundStyle(status == "completed" ? Color.studioTeal : status == "running" ? Color.studioGold : Color.secondary)
                Text(name).fontWeight(.medium);Spacer();Text(labels[status] ?? status).foregroundStyle(.secondary)
            }.font(.system(size:10))
            Text(detail).font(.system(size:9)).foregroundStyle(.secondary)
            if let start {
                Text(start.formatted(date:.omitted,time:.standard) + (end.map { " → " + $0.formatted(date:.omitted,time:.standard) } ?? " 起") + String(format:" · %.2f 秒",max(0,(end ?? Date()).timeIntervalSince(start)))).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children:.combine)
    }
}
