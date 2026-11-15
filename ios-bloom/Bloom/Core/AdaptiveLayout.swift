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

extension View {
    /// On iPhone Duo (iOS 27.1) a List's rows run under the floating title and the vertical bar,
    /// so give its scroll content margins there. Elsewhere it does nothing.
    func duoListClearance() -> some View {
        modifier(DuoListClearance())
    }
}

private struct DuoListClearance: ViewModifier {
    func body(content: Content) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(DuoListClearanceBars())
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
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        if let edge {
            content
                .contentMargins(.top, 80, for: .scrollContent)
                .contentMargins(edge == .trailing ? .trailing : .leading, 76, for: .scrollContent)
                .contentMargins(edge == .trailing ? .leading : .trailing, 16, for: .scrollContent)
        } else {
            content
        }
    }
}
#endif

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
