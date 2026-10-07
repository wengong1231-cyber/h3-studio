import SwiftUI

struct H3QueuePlanDetail: View {
    var plan: H3QueuePlan
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(plan.statusLabel,systemImage:plan.dependencyRequestID == nil ? "photo.badge.arrow.down" : "arrow.triangle.branch")
                .font(.system(size:12,weight:.medium)).foregroundStyle(Color.studioGold)
            Text(plan.actionGoal).font(.system(size:11)).lineSpacing(3)
            Text(plan.blocker).font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
            if let frame = plan.sourceGlobalFrameIndex {
                Text("当前母片 · 实际帧 \(frame)").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            }
            if plan.part == 1 {
                Text("身份参考 · 生成首图尚未准备").font(.system(size:10,weight:.medium))
                if plan.identityReferenceMatches {
                    AsyncPreviewImage(path:plan.identityReferencePath,revision:plan.identityReferenceSHA256,scope:.abReference,fit:true)
                        .frame(height:132).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:9))
                } else {
                    Label("身份参考缺失或指纹变化",systemImage:"exclamationmark.triangle").font(.system(size:10)).foregroundStyle(.secondary)
                }
                Text("原图仅供身份核对。本段生成首图将来自当前母片或已检查的前段端点。")
                    .font(.system(size:9)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Text("计划原生 \(plan.profile.frames) 帧 · 24 fps；选用 raw[\(plan.selectedRawStart),\(plan.selectedRawEnd))。")
                .font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            Text("已登记待办，尚未准备或执行。").font(.system(size:10)).foregroundStyle(.secondary)
        }.accessibilityElement(children:.contain)
    }
}
