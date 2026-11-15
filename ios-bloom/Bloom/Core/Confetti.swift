import SwiftUI

/// Lightweight pastel confetti burst. Change `trigger` to fire it.
struct ConfettiView: View {
    var trigger: Int
    var count: Int = 70

    @State private var pieces: [Piece] = []
    @State private var startDate: Date = .distantPast

    struct Piece {
        let x: CGFloat
        let vx: CGFloat
        let vy: CGFloat
        let spin: Double
        let color: Color
        let width: CGFloat
        let height: CGFloat
        let delay: Double
    }

    private let duration: Double = 3.2

    var body: some View {
        TimelineView(.animation(paused: pieces.isEmpty)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSince(startDate)
                guard t < duration + 0.6 else { return }
                for piece in pieces {
                    let lt = max(0, t - piece.delay)
                    let x = piece.x * size.width + piece.vx * CGFloat(lt) * 60
                    let y = -20 + piece.vy * CGFloat(lt) * 60 + 0.5 * 260 * CGFloat(lt * lt)
                    guard y < size.height + 40 else { continue }
                    let fade = lt > duration - 0.6 ? max(0, (duration - lt) / 0.6) : 1
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .degrees(piece.spin * lt * 120))
                    let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                    c.fill(Path(roundedRect: rect, cornerRadius: piece.width / 2), with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: trigger) { _, _ in fire() }
        .accessibilityHidden(true)
    }

    private func fire() {
        pieces = (0..<count).map { _ in
            Piece(
                x: .random(in: 0.05...0.95),
                vx: .random(in: -1.6...1.6),
                vy: .random(in: 1...4),
                spin: .random(in: -2...2),
                color: Theme.confettiColors.randomElement() ?? Theme.blush,
                width: .random(in: 8...11),
                height: .random(in: 18...26),
                delay: .random(in: 0...0.35)
            )
        }
        startDate = .now
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.7) {
            if Date.now.timeIntervalSince(startDate) >= duration { pieces = [] }
        }
    }
}
