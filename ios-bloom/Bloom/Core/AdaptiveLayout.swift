import SwiftUI

/// Chooses between a single column and two side-by-side panes.
///
/// Two panes are used only when the container is regular width AND wider than tall
/// (iPhone Duo inner display in landscape, iPad, large landscape iPhones). Everything
/// else — regular iPhones, the Duo outer display, a tall inner display — gets the
/// single-column layout, so no function is ever hidden by a pose.
///
/// The decision comes from size classes and the live container size, never from the
/// device model or screen bounds, so it re-evaluates smoothly on fold, unfold and rotate.
struct AdaptiveColumns<Primary: View, Secondary: View, Compact: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var compact: Compact

    @State private var size: CGSize = .zero

    private var isWide: Bool {
        horizontalSizeClass == .regular && size.width > size.height && size.width >= 640
    }

    var body: some View {
        ZStack {
            if isWide {
                // The canvas sits as a sibling behind the arrangement: a `.background`
                // modifier on ArrangementView is re-applied per pane at full-screen size,
                // which painted the canvas blobs over the panes. The compact branch
                // supplies its own background.
                ZStack {
                    BloomBackground()
                    TwoPaneLayout { primary } secondary: { secondary }
                }
                .transition(.opacity)
            } else {
                compact
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            size = newSize
        }
        .animation(.smooth(duration: 0.35), value: isWide)
    }
}

/// Two panes that sit on either side of the iPhone Duo fold.
/// Uses `ArrangementView` (iOS 27.1) when available; otherwise an equal HStack.
struct TwoPaneLayout<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split)
        } else {
            fallback
        }
#else
        fallback
#endif
    }

    private var fallback: some View {
        HStack(spacing: 0) {
            primary.frame(maxWidth: .infinity)
            secondary.frame(maxWidth: .infinity)
        }
    }
}

/// Which side of a two-pane layout a scroll view sits in. The Duo's vertical bar sits on one screen edge,
/// so only the pane next to that edge needs room for it.
enum PaneSide { case single, primary, secondary }

extension View {
    /// On iPhone Duo (iOS 27.1) a List's rows run under the floating title and the vertical bar,
    /// so give its scroll content margins there. Elsewhere it does nothing.
    func duoListClearance(pane: PaneSide = .single) -> some View {
        modifier(DuoListClearance(pane: pane))
    }
}

extension View {
    /// Bottom bars pinned with safeAreaInset: keep them clear of the Duo's vertical bar.
    func duoBarClearance() -> some View {
        modifier(DuoListClearance(barOnly: true))
    }
}

/// Shows its content only where the Duo's vertical toolbar bar is present; elsewhere nothing.
struct DuoBarOnly<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            DuoBarOnlyGate { content }
        }
#endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct DuoBarOnlyGate<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.toolbarVerticalEdge) private var edge
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Folded only: the open display keeps its top toolbar clear of the keyboard, so a copy there is a duplicate.
    var body: some View {
        if edge != nil, sizeClass == .compact { content }
    }
}
#endif

private struct DuoListClearance: ViewModifier {
    var barOnly = false
    var pane: PaneSide = .single

    func body(content: Content) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(DuoListClearanceBars(barOnly: barOnly, pane: pane))
        } else {
            content
        }
#else
        content
#endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct DuoListClearanceBars: ViewModifier {
    var barOnly: Bool
    var pane: PaneSide
    @Environment(\.toolbarVerticalEdge) private var edge

    /// The pane touching the bar's edge: the leading pane for a leading bar, the trailing one for a trailing bar.
    private func touchesBar(_ edge: HorizontalEdge) -> Bool {
        switch pane {
        case .single: true
        case .primary: edge == .leading
        case .secondary: edge == .trailing
        }
    }

    func body(content: Content) -> some View {
        if let edge, barOnly {
            content.padding(edge == .trailing ? .trailing : .leading, 72)
        } else if let edge {
            let barSide: Edge.Set = edge == .trailing ? .trailing : .leading
            let otherSide: Edge.Set = edge == .trailing ? .leading : .trailing
            content
                .contentMargins(.top, 80, for: .scrollContent)
                .contentMargins(barSide, touchesBar(edge) ? 76 : 16, for: .scrollContent)
                .contentMargins(otherSide, 16, for: .scrollContent)
        } else {
            content
        }
    }
}
#endif

/// A vertical scroll pane whose content is exactly as wide as the pane (minus Duo margins), so nothing is
/// clipped on the right and no space goes unused. Each pane scrolls on its own.
struct PaneScroll<Content: View>: View {
    var pane: PaneSide = .single
    var spacing: CGFloat = 18
    var horizontalPadding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
            // Not containerRelativeFrame: inside ArrangementView that resolves to the whole screen,
            // so each pane grew to 951 pt and the right one ran off the display.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .duoListClearance(pane: pane)
    }
}

/// Scroll container that vertically centres its content when it fits and scrolls
/// when it doesn't (short landscape heights, large Dynamic Type).
struct CenteredScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    /// Draws this view at `designSize` points square, then scales it down to fit its container.
    func fittedSquare(_ designSize: CGFloat) -> some View {
        FittedSquare(designSize: designSize) { self }
    }
}

/// Lays out a square artwork designed at `designSize` and scales it down to fit
/// the space it is given (never up), so illustrations adapt to any container.
struct FittedSquare<Content: View>: View {
    var designSize: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let scale = min(1, side / designSize)
            content
                .frame(width: designSize, height: designSize)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: designSize, maxHeight: designSize)
    }
}
