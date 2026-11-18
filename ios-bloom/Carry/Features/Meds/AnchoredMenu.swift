import SwiftUI

/// A small menu pinned to a control (the check circle), drawn by the pane that hosts it so it can
/// always fit inside the visible pane: width = min(320, pane − 32), 16 pt inside the pane's safe edges,
/// below the anchor when it fits, otherwise above. Replaces the system popover, which was clipped on
/// iPhone Duo because its arrow edge was forced to the top.
struct AnchoredMenuItem {
    var id: String
    var anchor: Anchor<CGRect>
    var content: AnyView
    var dismiss: () -> Void
}

struct AnchoredMenuKey: PreferenceKey {
    static let defaultValue: [AnchoredMenuItem] = []
    static func reduce(value: inout [AnchoredMenuItem], nextValue: () -> [AnchoredMenuItem]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Shows `content` anchored to this view while `isPresented`. Needs an `anchoredMenuHost()` above it.
    func anchoredMenu<Menu: View>(
        id: String,
        isPresented: Bool,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Menu
    ) -> some View {
        let menu = isPresented ? AnyView(content()) : nil
        return anchorPreference(key: AnchoredMenuKey.self, value: .bounds) { anchor in
            guard let menu else { return [] }
            return [AnchoredMenuItem(id: id, anchor: anchor, content: menu, dismiss: onDismiss)]
        }
    }

    /// Draws the open anchored menu of any descendant, kept inside this view's safe frame.
    func anchoredMenuHost() -> some View {
        overlayPreferenceValue(AnchoredMenuKey.self) { items in
            AnchoredMenuLayer(item: items.last)
        }
    }
}

private struct AnchoredMenuLayer: View {
    var item: AnchoredMenuItem?
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let margin: CGFloat = 16
    private let arrowHeight: CGFloat = 9
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let item {
                    // Tapping outside cancels, like the popover did.
                    Color.black.opacity(0.0001)
                        .contentShape(.rect)
                        .ignoresSafeArea()
                        .onTapGesture { item.dismiss() }
                        .accessibilityHidden(true)

                    menu(item, in: geo)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.3, dampingFraction: 0.86), value: item?.id)
        }
    }

    @ViewBuilder
    private func menu(_ item: AnchoredMenuItem, in geo: GeometryProxy) -> some View {
        let safe = CGRect(origin: .zero, size: geo.size)
        let anchor = geo[item.anchor]
        let width = max(0, min(320, safe.width - margin * 2))
        let offset = arrowHeight + gap
        let spaceBelow = safe.maxY - margin - (anchor.maxY + offset)
        let spaceAbove = (anchor.minY - offset) - (safe.minY + margin)
        let below = contentHeight <= spaceBelow || spaceBelow >= spaceAbove
        let available = max(120, below ? spaceBelow : spaceAbove)
        let height = min(contentHeight, available)
        let x = min(max(anchor.midX - width / 2, safe.minX + margin), max(safe.minX + margin, safe.maxX - margin - width))
        let rawY = below ? anchor.maxY + offset : anchor.minY - offset - height
        let y = min(max(rawY, safe.minY + margin), max(safe.minY + margin, safe.maxY - margin - height))
        let arrowX = min(max(anchor.midX - x, 26), width - 26)

        ScrollView {
            item.content
                .frame(width: width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(width: width, height: max(height, 1))
        .background(Theme.dayCard)
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.dayDivider, lineWidth: 0.5)
        }
        .overlay(alignment: below ? .topLeading : .bottomLeading) {
            MenuArrow(pointsUp: below)
                .fill(Theme.dayCard)
                .frame(width: 20, height: arrowHeight)
                .offset(x: arrowX - 10, y: below ? -arrowHeight + 0.5 : arrowHeight - 0.5)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .opacity(contentHeight > 0 ? 1 : 0)
        .offset(x: x, y: y)
        .transition(reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: below ? .top : .bottom)))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { item.dismiss() }
        .id(item.id)
    }
}

private struct MenuArrow: Shape {
    var pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - 4, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX + 4, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX - 4, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX + 4, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
