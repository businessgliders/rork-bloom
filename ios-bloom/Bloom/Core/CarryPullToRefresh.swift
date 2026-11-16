import SwiftUI

extension View {
    /// Pull to refresh with the Carry arc: it draws in as you pull, then spins while refreshing.
    /// iOS 17 falls back to the system control.
    @ViewBuilder
    func carryPullToRefresh(action: @escaping @MainActor () async -> Void) -> some View {
        if #available(iOS 18.0, *) {
            modifier(CarryPullToRefresh(action: action))
        } else {
            refreshable { await action() }
        }
    }
}

@available(iOS 18.0, *)
private struct CarryPullToRefresh: ViewModifier {
    var action: @MainActor () async -> Void

    private struct Pull: Equatable { var distance: CGFloat; var topInset: CGFloat }

    @State private var pull = Pull(distance: 0, topInset: 0)
    @State private var refreshing = false
    @State private var armed = true
    private let threshold: CGFloat = 72

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Pull.self) { geo in
                Pull(distance: max(0, -(geo.contentOffset.y + geo.contentInsets.top)), topInset: geo.contentInsets.top)
            } action: { _, new in
                pull = new
                if new.distance < 2, !refreshing { armed = true }
                if new.distance >= threshold, armed, !refreshing {
                    armed = false
                    start()
                }
            }
            .overlay(alignment: .top) {
                let share = min(1, pull.distance / threshold)
                Group {
                    if refreshing {
                        CarrySpinner(size: 26, color: Theme.rose)
                            .transition(.opacity)
                    } else if pull.distance > 6 {
                        CarryMark(size: 26, progress: share, dotScale: share >= 1 ? 1 : 0.0001)
                            .opacity(share)
                    }
                }
                .frame(width: 32, height: 32)
                .offset(y: refreshing ? max(14, pull.distance / 2 - 16) : pull.distance / 2 - 16)
                .padding(.top, pull.topInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private func start() {
        refreshing = true
        Haptics.tap()
        Task { @MainActor in
            await action()
            withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
        }
    }
}
