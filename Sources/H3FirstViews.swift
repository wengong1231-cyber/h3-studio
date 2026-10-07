import SwiftUI

struct H3FirstReferences: View {
    var job: ShotJob
    var body: some View {
        if let proposal = job.h3FirstProposal {
            VStack(alignment:.leading,spacing:12) {
                preview(proposal.isStaticInput ? "完整静态原图 · " + (proposal.queueExecution?.staticInput?.primary.stageLabel ?? "") : "实际源帧 · \(proposal.sourceFrameIndex)",path:proposal.input?.originalPath ?? job.h3InputPreparation?.images.first(where:{ $0.role == "original" })?.path,
                    revision:proposal.input?.originalSHA256 ?? proposal.sourceSHA256,placeholder:proposal.isStaticInput ? "开始后保存完整原图" : "开始后提取实际源帧")
                preview("完整画面 · 768×448",path:proposal.input?.normalizedPath ?? job.h3InputPreparation?.images.first(where:{ $0.role == "A" })?.path,
                    revision:proposal.input?.normalizedSHA256 ?? proposal.sourceSHA256,placeholder:"完整缩放与补边")
                if let binding = proposal.queueExecution?.staticInput {
                    ForEach(binding.motionReferences) { reference in
                        preview("身份/动作参考 · " + reference.stageLabel,path:reference.path,revision:reference.sha256,placeholder:"参考读取中")
                    }
                    if !binding.motionReferences.isEmpty { Text("参考图不作为连续端点，不连接末帧 port6；本次视频仍须检查实际脸部、箭和动作连续性。").font(.system(size:10)).foregroundStyle(Color.studioGold) }
                }
                Label(proposal.reviewReady ? "实际画面与提示词检查通过" : proposal.input != nil ? "画面完整性检查中" : "源帧准备后自动检查",
                    systemImage:proposal.reviewReady ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size:10)).foregroundStyle(proposal.reviewReady ? Color.studioTeal : .secondary)
            }
        }
    }
    private func preview(_ title: String,path: String?,revision: String,placeholder: String) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.system(size:10,weight:.medium))
            ZStack {
                RoundedRectangle(cornerRadius:9).fill(Color.secondary.opacity(0.06))
                if let path { AsyncPreviewImage(path:path,revision:revision,scope:.abReference,fit:true).padding(4) }
                else { Label(placeholder,systemImage:"photo").font(.system(size:10)).foregroundStyle(.secondary) }
            }.frame(height:142).accessibilityLabel(title + "，完整画面预览")
        }
    }
}

struct H3FirstTaskTimeline: View {
    var job: ShotJob
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("任务步骤").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            step(job.h3FirstProposal?.isStaticInput == true ? "完整静态图与归一预览" : "精确源帧与归一预览",status:job.h3InputPreparation?.status ?? "waiting",
                detail:job.h3FirstProposal?.isStaticInput == true ? "实际原图 SHA、完整解码、无裁切补边" : "实际帧位、母片指纹、完整画面变换",start:job.h3InputPreparation?.startedAt,end:job.h3InputPreparation?.endedAt)
            step("画面与提示词检查",status:job.h3FirstProposal?.reviewReady == true ? "completed" : job.h3FirstProposal?.input != nil && job.status.isPending ? "running" : "waiting",
                detail:"绑定实际原帧、归一图与提示词",start:nil,end:job.h3FirstProposal?.pixelReview?.inspectedAt)
            step("第\(job.h3FirstProposal?.part ?? 1)段视频生成",status:job.h3GenerationStartedAt == nil ? "waiting" : job.h3GenerationEndedAt == nil ? "running" : job.h3ValidationStartedAt != nil ? "completed" : job.status.rawValue,
                detail:"A 首帧 · 原生 \(job.parameters.frames ?? 90) 帧",start:job.h3GenerationStartedAt,end:job.h3GenerationEndedAt)
            step("完整音视频与逐帧检查",status:job.h3ValidationStartedAt == nil ? "waiting" : job.h3ValidationEndedAt == nil ? "running" : job.h3Outcome?.technicalPass == true ? "completed" : job.status.rawValue,
                detail:job.h3Outcome?.technicalPass == true ? "技术通过 · 本段候选已保存" : "实际帧数、尺寸、完整音视频解码",start:job.h3ValidationStartedAt,end:job.h3ValidationEndedAt)
        }.accessibilityElement(children:.contain)
    }
    private func step(_ title: String,status: String,detail: String,start: Date?,end: Date?) -> some View {
        let label = ["waiting":"未开始","running":"处理中","completed":"已完成","failed":"失败","cancelled":"已取消","interrupted":"已中断"][status] ?? "未开始"
        return VStack(alignment:.leading,spacing:5) {
            HStack {
                Image(systemName:status == "completed" ? "checkmark.circle.fill" : status == "running" ? "circle.dotted" : "circle")
                    .foregroundStyle(status == "completed" ? Color.studioTeal : status == "running" ? Color.studioGold : .secondary)
                Text(title).fontWeight(.medium);Spacer();Text(label).foregroundStyle(.secondary)
            }.font(.system(size:10))
            Text(detail).font(.system(size:9)).foregroundStyle(.secondary)
            if let start {
                Text(start.formatted(date:.omitted,time:.standard) + (end.map { " → " + $0.formatted(date:.omitted,time:.standard) } ?? " 起")
                    + String(format:" · %.2f 秒",max(0,(end ?? Date()).timeIntervalSince(start))))
                    .font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children:.combine)
    }
}
