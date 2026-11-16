import SwiftUI

/// Carry's signature flower. Petals fill with blush from the bottom as `fill` goes 0 → 1.
struct FlowerIllustration: View {
    var fill: Double

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let headCenter = CGPoint(x: w / 2, y: h * 0.36)
            let petalLength = min(w, h) * 0.34

            ZStack {
                // Stem
                Capsule()
                    .fill(Theme.sage)
                    .frame(width: w * 0.05, height: h * 0.5)
                    .position(x: w / 2, y: h * 0.72)
                // Leaves
                Ellipse()
                    .fill(Theme.sage)
                    .frame(width: w * 0.3, height: h * 0.11)
                    .rotationEffect(.degrees(-24))
                    .position(x: w * 0.36, y: h * 0.78)
                Ellipse()
                    .fill(Theme.sage.opacity(0.85))
                    .frame(width: w * 0.3, height: h * 0.11)
                    .rotationEffect(.degrees(24))
                    .position(x: w * 0.64, y: h * 0.74)

                // Petals (empty layer)
                petals(length: petalLength)
                    .fill(Theme.blushSoft)
                    .overlay(petals(length: petalLength).stroke(Theme.blush.opacity(0.5), lineWidth: 2))
                    .frame(width: w, height: h)

                // Petals (filled layer, masked from the bottom)
                petals(length: petalLength)
                    .fill(Theme.blush)
                    .frame(width: w, height: h)
                    .mask(alignment: .bottom) {
                        let top = headCenter.y - petalLength
                        let bottom = headCenter.y + petalLength
                        let span = bottom - top
                        Rectangle()
                            .frame(height: (h - bottom) + span * max(0, min(fill, 1)))
                    }

                // Centre
                Path { path in
                    for i in 0..<3 {
                        let angle = Double(i - 1) * 28 * .pi / 180
                        path.move(to: headCenter)
                        path.addLine(to: CGPoint(
                            x: headCenter.x + sin(angle) * petalLength * 0.55,
                            y: headCenter.y - cos(angle) * petalLength * 0.55
                        ))
                    }
                }
                .stroke(Theme.butter, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ForEach(0..<3, id: \.self) { i in
                    let angle = Double(i - 1) * 28
                    Circle()
                        .fill(Theme.butter)
                        .frame(width: 10, height: 10)
                        .position(
                            x: headCenter.x + sin(angle * .pi / 180) * petalLength * 0.55,
                            y: headCenter.y - cos(angle * .pi / 180) * petalLength * 0.55
                        )
                }
                Circle()
                    .fill(Theme.butter)
                    .frame(width: petalLength * 0.32)
                    .position(headCenter)
            }
        }
        .accessibilityHidden(true)
    }

    private func petals(length: CGFloat) -> PetalsShape {
        PetalsShape(length: length, centerYFraction: 0.36)
    }
}

struct PetalsShape: Shape {
    var length: CGFloat
    var centerYFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.height * centerYFraction)
        var path = Path()
        let count = 5
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let petal = CGRect(x: -length * 0.32, y: -length, width: length * 0.64, height: length)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle + .pi / 2)
            path.addEllipse(in: petal, transform: transform)
        }
        return path
    }
}
