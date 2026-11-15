import SwiftUI

extension EnvironmentValues {
    /// The name of the person whose meds are on screen when it isn't the viewer (nil = "you").
    @Entry var medsPerson: String? = nil
}

/// Small wording helpers so "you" lines read right for the partner's meds.
enum PersonWording {
    static func takes(_ person: String?) -> String { person.map { "\($0) takes" } ?? "you take" }
    static func took(_ person: String?) -> String { person.map { "\($0) took" } ?? "you took" }
}

/// "Mine" / partner's name switcher shown on the Meds tab when the pregnancy is shared.
struct MedsPersonSwitcher: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: MedOwner

    var body: some View {
        HStack(spacing: 6) {
            chip(store.viewerRole, title: "Mine")
            chip(store.viewerRole.other, title: store.name(for: store.viewerRole.other))
        }
        .padding(4)
        .background(Theme.surface, in: .capsule)
        .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(0.1), radius: 8, y: 3)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whose meds")
    }

    private func chip(_ owner: MedOwner, title: String) -> some View {
        let selected = selection == owner
        let count = store.medications.filter { $0.owner == owner && $0.isActive(on: store.now) }.count
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = owner }
        } label: {
            HStack(spacing: 6) {
                Text(owner == .mom ? "🤰" : "🫶").font(.system(size: 15))
                Text(title)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.bloom(.caption, weight: .semibold))
                        .foregroundStyle(selected ? Theme.blushDeep : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(selected ? Theme.surface : Theme.surfaceMuted, in: .capsule)
                }
            }
            .foregroundStyle(selected ? Theme.blushDeep : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background {
                if selected { Capsule().fill(Theme.blushSoft) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
