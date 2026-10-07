import SwiftUI

extension ActivityTone {
    var color: Color {
        switch self {
        case .working,.attention: return .studioGold
        case .success: return .studioTeal
        case .failure: return .red.opacity(0.85)
        case .waiting: return .secondary
        }
    }
}

struct ActivityStatusCard: View {
    var value: ActivityPresentation
    var task: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(alignment:.top,spacing:7) {
                Image(systemName:value.symbol).foregroundStyle(value.tone.color)
                Text(value.state).fontWeight(.semibold).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:4)
            }.font(.system(size:11))
            if let task { Text(task).font(.system(size:13,weight:.medium)).lineLimit(2) }
            Text(value.stage).font(.system(size:11,weight:.medium)).fixedSize(horizontal:false,vertical:true)
            HStack(alignment:.top,spacing:10) {
                Label(value.elapsedDescription,systemImage:"clock")
                if let phase = value.stageElapsed { Text(phase) }
            }.font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).monospacedDigit()
            if let progress = value.progress {
                ProgressView(value:progress.fraction).tint(value.tone.color)
                Text(progress.label + " · 仅当前阶段").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:4) {
                Text(value.lastProgress)
                if let heart = value.heartbeat { Text(heart + " · 进程存活不等于任务推进") }
            }.font(.system(size:9)).foregroundStyle(.secondary).monospacedDigit()
            Text(value.detail).font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(3)
            if let next = value.nextStep { Text(next).font(.system(size:9)).foregroundStyle(value.tone == .failure ? Color.red.opacity(0.8) : .secondary).lineSpacing(3) }
        }.padding(13).frame(maxWidth:.infinity,alignment:.leading)
            .background(Palette(scheme:scheme).raised.opacity(0.65))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(value.tone.color.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius:10))
            .accessibilityElement(children:.combine)
    }
}
