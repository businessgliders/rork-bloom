import SwiftUI

/// Chooses between a single column and two side-by-side panes.
///
/// Two panes are used only when the container is regular width AND at least 800 pt wide
/// (iPhone Duo inner display in landscape, iPad, large landscape iPhones). Everything
/// else — regular iPhones, the Duo outer display, the inner display in portrait — gets the
/// single-column layout, so no function is ever hidden by a pose.
///
/// The decision comes from the size class and the live container width only, never the height
/// (the keyboard shrinks it) or the device model, so it re-evaluates smoothly on fold, unfold and
/// rotate. While `\.freezeAdaptiveColumns` is true (an editor has focus) the column count holds.
struct AdaptiveColumns<Primary: View, Secondary: View, Compact: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.freezeAdaptiveColumns) private var frozen
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var compact: Compact

    @State private var width: CGFloat = 0
    @State private var heldWide: Bool?

    private var measuredWide: Bool {
        horizontalSizeClass == .regular && width >= 800
    }

    private var isWide: Bool {
        frozen ? (heldWide ?? measuredWide) : measuredWide
    }

    var body: some View {
        ZStack {
            if isWide {
                // The canvas sits as a sibling behind the arrangement: a `.background`
                // modifier on ArrangementView is re-applied per pane at full-screen size,
                // which painted the canvas blobs over the panes. The compact branch
                // supplies its own background.
                ZStack {
                    CarryBackground()
                    TwoPaneLayout { primary } secondary: { secondary }
                }
                .transition(.opacity)
            } else {
                compact
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onChange(of: frozen, initial: true) { _, isFrozen in
            heldWide = isFrozen ? measuredWide : nil
        }
        .animation(.smooth(duration: 0.35), value: isWide)
    }
}

extension EnvironmentValues {
    /// Keeps `AdaptiveColumns` at its current column count (e.g. while a text editor has focus).
    @Entry var freezeAdaptiveColumns: Bool = false
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

    /// PaneScroll: room under the floating title only. Sideways the system's safe area already clears the bar,
    /// so content runs to 20 pt from the bar's leading edge with the scroll indicator beside it.
    fileprivate func duoPaneClearance(pane: PaneSide) -> some View {
        modifier(DuoListClearance(pane: pane, paneScroll: true))
    }

    /// Inside PaneScroll: the bar sits a little inside the safe-area edge, so trim the bar-side padding to keep
    /// a 20 pt gap to the bar itself rather than 30.
    fileprivate func duoBarSideTrim(pane: PaneSide) -> some View {
        modifier(DuoBarSideTrim(pane: pane))
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

private struct DuoBarSideTrim: ViewModifier {
    var pane: PaneSide

    func body(content: Content) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(DuoBarSideTrimBars(pane: pane))
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
private struct DuoBarSideTrimBars: ViewModifier {
    var pane: PaneSide
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        if let edge, pane.touchesBar(edge) {
            content.padding(edge == .trailing ? .trailing : .leading, -10)
        } else {
            content
        }
    }
}
#endif

extension PaneSide {
    /// The pane touching the bar's edge: the leading pane for a leading bar, the trailing one for a trailing bar.
    func touchesBar(_ edge: HorizontalEdge) -> Bool {
        switch self {
        case .single: true
        case .primary: edge == .leading
        case .secondary: edge == .trailing
        }
    }
}

private struct DuoListClearance: ViewModifier {
    var barOnly = false
    var pane: PaneSide = .single
    var paneScroll = false

    func body(content: Content) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(DuoListClearanceBars(barOnly: barOnly, pane: pane, paneScroll: paneScroll))
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
    var paneScroll: Bool
    @Environment(\.toolbarVerticalEdge) private var edge

    private func touchesBar(_ edge: HorizontalEdge) -> Bool { pane.touchesBar(edge) }

    func body(content: Content) -> some View {
        if barOnly {
            // safeAreaInset bars already stop at the bar's safe-area edge; extra padding left a 72 pt gap.
            content
        } else if edge != nil, paneScroll {
            content.contentMargins(.top, 80, for: .scrollContent)
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
            .duoBarSideTrim(pane: pane)
            .padding(.top, 8)
            .padding(.bottom, 24)
            // Not containerRelativeFrame: inside ArrangementView that resolves to the whole screen,
            // so each pane grew to 951 pt and the right one ran off the display.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .duoPaneClearance(pane: pane)
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
