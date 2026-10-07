import Foundation
import SwiftUI
import AppKit

enum H3FidelityFinding: String, Codable, CaseIterable, Identifiable {
    case detailImproved, codecDistortion, motionIdentityDrift, sourceInsufficient, actionMismatch, samplePreserved, needsMoreReview
    var id: String { rawValue }
    static func choices(for kind: H3FidelityKind) -> [Self] {
        allCases.filter {
            if $0 == .motionIdentityDrift || $0 == .actionMismatch { return kind.isMotion }
            if $0 == .detailImproved { return kind == .codecDetail }
            if $0 == .codecDistortion { return !kind.isMotion }
            return true
        }
    }
    var title: String {
        switch self {
        case .detailImproved: return "高分辨率保留了更多脸部细节"
        case .codecDistortion: return "仅编解码仍改变人脸"
        case .motionIdentityDrift: return "生成动作时人脸改变"
        case .sourceInsufficient: return "原图的人脸信息不足"
        case .actionMismatch: return "动作或肢体不符合要求"
        case .samplePreserved: return "已检查样本暂未见明显变化"
        case .needsMoreReview: return "证据不足，需继续检查"
        }
    }
}

struct H3FidelityGuidance: Codable, Equatable {
    var title: String
    var codeHandling: String
    var nextStep: String
    var requiredInputs: String
    var promptPurpose: String?
    var prompt: String?
    var blocksQuality = true
    static let executionFailure = Self(title:"对照执行失败：尚无有效画面结论",codeHandling:"先由开发核对引擎错误与管线条件；失败不等于人脸已检查。旧失败保留，只有明确改变方案后才再运行。",nextStep:"诊断并修正执行问题，再通过应用进行新的对照。",requiredInputs:"当前无需补图或重写Prompt；原任务和日志已保留。")

    static func make(_ finding: H3FidelityFinding,shot: Int,kind: H3FidelityKind,verifiedDetailImprovement: Bool = false) -> Self {
        switch finding {
        case .detailImproved:
            return .init(title:"细节改善，动作保真仍待验证",codeHandling:"应用可直接从原图按1536×896准备输入，减少缩小造成的细节损失；不会超分旧视频。",nextStep:"继续22帧原生运动对照，检查每张脸、肢体和龙的动作。通过前不扩大生成。",requiredInputs:"无需重复提供现有原图。",blocksQuality:false)
        case .codecDistortion:
            return .init(title:"未通过：编解码后人脸已改变",codeHandling:"这是编解码对照的差异，提示词不会参与这一步。开发需先检查像素归一、潜在帧布局和引擎实现。",nextStep:"保留本次输出并诊断编解码；不能靠修改动作提示词重试。",requiredInputs:"当前无需补图；已有原图、实际输入、输出帧和引擎日志足以开始定位。")
        case .motionIdentityDrift:
            if kind == .motionKeyframeDetail {
                return .init(title:"未通过：首尾同图仍改变人脸",codeHandling:"已将同一完整原图真正接入首尾两帧，但中间生成仍改变身份。首尾约束不能当作持续身份锁，也不能凭提示词或超分宣称修好。",nextStep:"保留全部对照，停止同配置重试。先验证本机引擎的持续参考能力与所需组件，能力未具备时明确列出缺口，再决定新的受控方案。",requiredInputs:"当前无需重复补图；已有READY、静态及首尾约束对照足够定位。需要新接触姿态时先由应用工作流准备，并单独检查同脸同构图。",promptPurpose:"下一方案的动作约束草稿，尚未应用",prompt:motionPrompt(shot:shot))
            }
            if verifiedDetailImprovement {
                return .init(title:"未通过：静态细节改善，运动仍改变人脸",codeHandling:"同一原图的高分辨率静态对照已有改善，但运动生成仍改变身份。当前H3没有经过验证的人脸身份约束，不能把更高分辨率或Prompt当作修复完成。",nextStep:"开发先核对首帧条件的实际约束路径；若引擎无法保持身份，需接入可验证的身份参考或受控关键帧方案后再做短段对照。保留当前失败，不原样重跑。",requiredInputs:"当前无需重复补图：已有完整READY、静态对照和运动帧足够定位。后续方案若需要各张脸的独立参考，先从现有原图取得；需要新的接触或回弹姿态时再明确列出。",promptPurpose:"下一方案的动作约束草稿，尚未应用",prompt:motionPrompt(shot:shot))
            }
            return .init(title:"未通过：运动生成改变了身份",codeHandling:"应用可以约束输入、尺寸和动作幅度，但当前H3没有经过验证的人脸身份锁。提示词不能保证同一张脸。",nextStep:"核对编解码结果；若该步正常，再使用更明确的身份参考和更小动作做新的受控试验。",requiredInputs:shot == 26 ? "需要同一三头角色各张脸的清晰参考，以及保持现有完整构图的READY图；参考须与要保留的脸一致。先尝试从现有原图取得，不足时才补图。" : "需要要保留的人脸清晰参考与同一构图的完整起势图；先检查现有素材能否提供。",promptPurpose:"重绘身份与起势参考图",prompt:referencePrompt(shot:shot))
        case .sourceInsufficient:
            return .init(title:"未通过：原图缺少可用的人脸细节",codeHandling:"缩放或锐化不能恢复原图中不存在的身份信息。应用会保持完整构图，不裁掉人物或龙。",nextStep:"补齐清晰参考后，通过App重新绑定、归一和图审。",requiredInputs:shot == 26 ? "完整READY构图；三张分别清晰、无遮挡的脸部参考。若重画动作，还需接触与回弹姿态参考，不能把命中终态当起势。" : "完整起势图、同一角色清晰脸部参考；需要复杂动作时再提供关键姿态图。",promptPurpose:"重绘完整起势图",prompt:referencePrompt(shot:shot))
        case .actionMismatch:
            return .init(title:"未通过：动作或肢体不符合要求",codeHandling:"应用可拆分动作、绑定明确起止姿态；不能靠文字保证复杂碰撞中的肢体始终正确。",nextStep:"先修订单次接触动作，必要时拆成接近、碰撞、回弹三段，各段独立检查。",requiredInputs:shot == 26 ? "保持同脸同构图的接触姿态与回弹姿态参考；现有READY只作起势。" : "同一角色、同一构图的起势、关键接触与收势参考。",promptPurpose:"视频动作修订草稿，尚未应用",prompt:motionPrompt(shot:shot))
        case .samplePreserved:
            return .init(title:"样本已检查，完整候选仍待验收",codeHandling:"所看样本暂未发现明显身份变化；这不代表其余帧、完整动作或续段已通过。",nextStep:kind.isMotion ? "检查全部22帧和连续播放，再决定是否进行完整段试验。" : "继续原生运动对照，确认动作生成不会重新改变人脸。",requiredInputs:"当前无需新素材；先完成已有输出的检查。",blocksQuality:false)
        case .needsMoreReview:
            return .init(title:"尚不能判断人脸是否保持",codeHandling:"技术完成只证明输出可读，不能自动证明脸部相同。",nextStep:"查看原尺寸的原图、编解码结果和生成帧，逐项记录具体差异。",requiredInputs:"无需先补图；先补充实际像素检查与差异位置。")
        }
    }
    private static func referencePrompt(shot: Int) -> String {
        if shot == 26 {
            return """
            Edit the supplied complete S26 READY image using the supplied face references. Preserve the original wide composition, camera angle, character scale, dragon position, waves, lighting and painted style. Keep Nezha as one three-headed, six-armed character riding exactly two fire wheels. Match each head to its corresponding supplied face reference: preserve youthful facial proportions, eyes, nose, mouth, hairline and hairstyle; no beautification that changes identity, no aged or monstrous face, no merged heads. Keep all three faces readable and separated. Preserve six coherent arms and hands, the connected spear, flowing red ribbon and both complete wheels. Nezha and the dragon face one another before contact; the spear is ready. Preserve the full dragon head and horns and the visible body silhouette from the original frame; do not invent unseen body parts or reframe to reveal the entire dragon. This is the preparation pose, not the collision or recoil. Do not crop, enlarge or redesign the character to hide a face problem. Do not add limbs, heads, weapons, text or subtitles. Output the complete frame at the highest available native detail; no generated-video upscaling.
            """
        }
        return "Edit the supplied complete READY image using the supplied approved face reference. Preserve the full composition, camera, character scale, pose, wardrobe, anatomy, lighting and style. Match the original identity and face proportions exactly; preserve the eyes, nose, mouth, hairline and hairstyle. Resolve only missing or malformed facial details using the reference. Keep all required subjects and limbs visible. Do not use an ending pose as the starting pose. Do not add text, subtitles, extra limbs or new facial features. Output a complete frame with clear native detail."
    }
    private static func motionPrompt(shot: Int) -> String {
        if shot == 26 {
            return """
            One continuous locked-camera wide shot matching the supplied S26 READY image. Nezha keeps exactly three distinct youthful heads, the same three faces and hairstyles, six anatomically connected arms, one spear and two complete fire wheels. The face shapes and expression remain stable. Nezha glides a short distance toward the dragon on the existing wheels. The dragon moves its head forward to meet the spear; show one clear, brief contact between the spear tip and the dragon's forehead. Both react to the same contact: Nezha's arms absorb the impact while the dragon's head recoils slightly. Nezha then draws back a little and settles; the dragon settles in response. Keep the spear continuously connected to the same hands with only a small angle change. Keep all three heads, six hands, both wheels and the dragon's head and horns inside the frame; retain the original visible dragon-body silhouette without inventing unseen parts. Cloth, ribbon, hair, waves and dragon body follow the main motion with small delayed movement. No camera zoom, cuts, facial redesign, fused heads, extra limbs, detached hands, sudden spear flip, repeated hits, text or subtitles.
            """
        }
        return "Use the supplied READY frame and matching key-pose references in one continuous shot. Preserve the same faces, anatomy, wardrobe, framing and camera. Perform only the single reviewed action: a small deliberate preparation, one clearly connected contact or gesture, then a short recoil and stable finish. The body, hands and held objects move coherently; hair and cloth follow with slight delay. No face redesign, extra limbs, detached objects, clipping, camera zoom, cuts, text or subtitles. Replace the action description with the shot's exact reviewed goal before binding this draft in the App."
    }
}

struct H3FidelityGuidanceCard: View {
    let value: H3FidelityGuidance
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Label(value.title,systemImage:value.blocksQuality ? "exclamationmark.triangle.fill" : "eye").font(.headline)
            Text("应用处理：" + value.codeHandling)
            Text("下一步：" + value.nextStep)
            Text("需要提供：" + value.requiredInputs)
            if let prompt = value.prompt,let purpose = value.promptPurpose {
                DisclosureGroup(purpose) { Text(prompt).textSelection(.enabled).font(.system(size:11)).padding(.top,6) }
                Button("复制" + purpose) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(prompt,forType:.string) }
                    .accessibilityIdentifier("fidelity.copy-prompt")
                Text("这是针对当前差异的草稿；复制不会改动冻结输入，也不代表身份保证。")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            }
        }.font(.system(size:12)).lineSpacing(3).textSelection(.enabled)
            .frame(maxWidth:.infinity,alignment:.leading).padding(14)
            .background((value.blocksQuality ? Color.red : Color.orange).opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(value.blocksQuality ? Color.red.opacity(0.5) : Color.orange.opacity(0.4)))
            .clipShape(RoundedRectangle(cornerRadius:10))
            .accessibilityIdentifier("fidelity.guidance")
    }
}
