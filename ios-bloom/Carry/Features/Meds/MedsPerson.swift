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

/// "Mine" | "Jaismine's": the compact person switch on Meds today and Meds & routines.
/// Shown only when both people take meds; the choice is remembered on this phone.
struct MedsPersonSwitch: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            segment(partner: false, title: "Mine")
            segment(partner: true, title: "\(store.name(for: store.viewerRole.other))'s")
        }
        .padding(3)
        .frame(height: Self.height)
        .background(Theme.dayCard, in: .capsule)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
        .fixedSize()
    }

    private func segment(partner: Bool, title: String) -> some View {
        let selected = store.medsShowsPartner == partner
        return Button {
            Self.choose(partner: partner, store: store, reduceMotion: reduceMotion)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Theme.daySecondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .background {
                    if selected {
                        if reduceMotion {
                            Capsule().fill(Theme.rose).transition(.opacity)
                        } else {
                            Capsule().fill(Theme.rose).matchedGeometryEffect(id: "selected", in: pill)
                        }
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(partner ? "\(title) meds" : "My meds")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(partner ? "meds-person-partner" : "meds-person-mine")
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Switches with a light haptic; a fade when Reduce Motion is on.
    static func choose(partner: Bool, store: AppStore, reduceMotion: Bool) {
        guard store.bothTakeMeds, store.medsShowsPartner != partner else { return }
        Haptics.light()
        withAnimation(animation(reduceMotion: reduceMotion)) { store.medsShowsPartner = partner }
    }
}

/// Swipe left for the partner, right for Mine, on a screen's header.
struct MedsPersonSwipe: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard store.bothTakeMeds, abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                        MedsPersonSwitch.choose(partner: dx < 0, store: store, reduceMotion: reduceMotion)
                    },
                including: store.bothTakeMeds ? .all : .subviews
            )
    }
}

extension View {
    func medsPersonSwipe() -> some View { modifier(MedsPersonSwipe()) }
}
