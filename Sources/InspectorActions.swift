import SwiftUI
import AppKit

struct InspectorAction: Identifiable {
    var id: String
    var title: String
    var icon: String
    var enabled = true
    var perform: () -> Void
    @MainActor func trigger() {
        // A CPU preparation can finish between clicks and change the primary
        // action from prepare to review. The second click must not approve it,
        // or turn a just-reviewed task into an unintended generation launch.
        if let event = NSApp?.currentEvent,
           [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1 { return }
        perform()
    }
}

/// A full-width primary action and an adaptive secondary grid keep the 302 pt
/// inspector readable, including when several task actions are available.
struct InspectorActionBar: View {
    var primary: InspectorAction?
    var secondary: [InspectorAction]
    var caption: String? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let primary {
                Button(action: primary.trigger) {
                    Label(primary.title, systemImage: primary.icon)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(StudioPrimaryButtonStyle()).disabled(!primary.enabled)
                .accessibilityIdentifier("inspector." + primary.id)
            }
            if !secondary.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(secondary) { action in
                        Button(action: action.trigger) {
                            Label(action.title, systemImage: action.icon)
                                .font(.system(size: 11)).lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(Palette(scheme: scheme).raised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).disabled(!action.enabled)
                        .accessibilityIdentifier("inspector." + action.id)
                    }
                }
            }
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
