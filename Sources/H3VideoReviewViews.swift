import SwiftUI

struct H3VideoReviewCard: View {
    var job: ShotJob
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            let accepted = job.h3VideoRejection == nil && job.h3VideoReview?.isTrustedAcceptance == true
            Label(job.supersededBy != nil ? "原候选已重做 · 历史保留" : job.h3VideoRejection != nil ? "候选已拒绝 · 不再放行续段" : accepted ? "本段已接受 · 操作记录保留" : job.h3VideoReview != nil ? "旧操作记录保留 · 可接受当前候选" : "候选已就绪 · 可在应用中接受",systemImage:accepted ? "checkmark.seal" : "play.rectangle")
                .font(.system(size:11,weight:.medium)).foregroundStyle(accepted ? Color.studioTeal : .studioGold)
            if let plan = job.h3QueuePlan {
                Text("选用 raw[\(plan.selectedRawStart),\(plan.selectedRawEnd)) · 原生端帧 raw\(plan.selectedRawEnd-1)").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                if let binding = job.h3Binding {
                    AsyncPreviewImage(path:binding.outputDirectory + String(format:"/record/lossless-frames/frame-%04d.png",plan.selectedRawEnd-1),
                        revision:job.h3VideoReview?.endpointSHA256 ?? binding.jobSHA256,scope:.abReference,fit:true)
                        .frame(height:104).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:8))
                }
            }
            if let rejected = job.h3VideoRejection {
                Text(rejected.reason).font(.system(size:11,weight:.medium)).foregroundStyle(Color.studioGold)
                Text("拒绝来源：" + rejected.sourceReference + " · 操作者 " + rejected.actorKind).font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let review = job.h3VideoReview {
                ForEach(review.knownVisualRisks,id:\.self) { risk in Label(risk,systemImage:"exclamationmark.triangle").font(.system(size:10)).foregroundStyle(Color.studioGold) }
                Text(review.observation).font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                Text("来源记录 " + review.evidenceID + " · " + review.reviewedAt.formatted(date:.abbreviated,time:.shortened))
                    .font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("候选 " + String(review.clipSHA256.prefix(12)) + " · 端帧 " + String(review.endpointSHA256.prefix(12)))
                    .font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary)
                Text("输入来源：" + (review.provenance?.origin ?? "旧回执未记录") + " · 操作者：" + (review.provenance?.actorKind ?? "未知"))
                    .font(.system(size:9)).foregroundStyle(.secondary)
                if let reference = review.provenance?.sourceReference { Text(reference).font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
            } else {
                Text("技术检查已通过。查看候选与端帧后，在应用中接受即可接续，无需聊天里重复确认。")
                    .font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.studioGold.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius:9))
            .accessibilityElement(children:.combine)
    }
}

struct H3DependencyReviewCard: View {
    var previous: ShotJob
    var rawIndex: Int
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            let accepted = previous.videoContinuationAuthorized
            Label(accepted ? "前段已接受 · 端帧已绑定" : previous.status == .completed ? "等待前段用户视频确认" : "等待前段完成",systemImage:accepted ? "checkmark.circle" : "clock")
                .font(.system(size:11,weight:.medium)).foregroundStyle(accepted ? Color.studioTeal : .studioGold)
            Text("依赖 \(previous.shortID) 第\(previous.h3QueuePlan?.part ?? 1)段 · raw\(rawIndex)").font(.system(size:10,weight:.medium))
            if let review = previous.h3VideoReview {
                ForEach(review.knownVisualRisks,id:\.self) { risk in Label(risk,systemImage:"exclamationmark.triangle").font(.system(size:10)).foregroundStyle(Color.studioGold) }
                Text(review.observation).font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
                Text((accepted ? "已接受候选 " : "待核对候选 ") + String(review.clipSHA256.prefix(12)) + " · 原生端帧 " + String(review.endpointSHA256.prefix(12)))
                    .font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                Text("来源记录：" + review.evidenceID).font(.system(size:8,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            } else if previous.status == .completed {
                Text("前段已技术通过。在前段结果中接受并继续，操作会绑定当前候选和本段任务。")
                    .font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
            } else { Text("前段当前状态：" + previous.displayStatusLabel).font(.system(size:10)).foregroundStyle(.secondary) }
            Text("本段原图检查由助手执行，无需逐张人工确认。").font(.system(size:9)).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.studioGold.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius:9))
            .accessibilityElement(children:.combine)
    }
}
