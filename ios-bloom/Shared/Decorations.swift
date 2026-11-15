import SwiftUI

/// A soft organic blob used behind illustrations.
struct BlobShape: Shape {
    var seed: Int = 0

    func path(in rect: CGRect) -> Path {
        let points = 8
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var generator = SeededGenerator(seed: UInt64(seed + 7))
        let radii: [CGFloat] = (0..<points).map { _ in radius * CGFloat.random(in: 0.84...1.0, using: &generator) }

        func point(_ i: Int) -> CGPoint {
            let angle = (CGFloat(i) / CGFloat(points)) * .pi * 2 - .pi / 2
            let r = radii[(i % points + points) % points]
            return CGPoint(x: center.x + cos(angle) * r * (rect.width / (2 * radius)),
                           y: center.y + sin(angle) * r * (rect.height / (2 * radius)))
        }

        var path = Path()
        let first = point(0)
        let last = point(points - 1)
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in 0..<points {
            let current = point(i)
            let next = point(i + 1)
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.closeSubpath()
        return path
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Warm cream canvas with soft peach corner blobs, the Bloom atmosphere.
struct BloomBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.canvas
                Circle()
                    .fill(Theme.peachSoft)
                    .frame(width: proxy.size.width * 0.7)
                    .position(x: -proxy.size.width * 0.08, y: -proxy.size.width * 0.02)
                Circle()
                    .fill(Theme.blushSoft.opacity(0.8))
                    .frame(width: proxy.size.width * 0.6)
                    .position(x: proxy.size.width * 1.05, y: proxy.size.height * 1.0)
            }
        }
        .ignoresSafeArea()
    }
}

/// Circular progress ring with rounded caps.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 18
    var tint: Color = Theme.sage
    var track: Color = Theme.ringTrack

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Small sparkle accent ("shine lines") like the design's fruit highlight.
struct ShineMarks: View {
    var color: Color = Theme.butter
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 6, height: 18)
                    .offset(y: -14)
                    .rotationEffect(.degrees(Double(i) * 38 - 10))
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}
