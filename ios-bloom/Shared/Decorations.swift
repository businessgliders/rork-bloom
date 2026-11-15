import SwiftUI

/// The plain system grouped background used behind every screen.
struct BloomBackground: View {
    var body: some View {
        Theme.canvas.ignoresSafeArea()
    }
}

/// Circular progress ring with rounded caps.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 12
    var tint: Color = Theme.blush
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
