import SwiftUI
import WidgetKit

/// Plain system surface behind every widget.
struct WidgetCanvas: View {
    var body: some View {
        Theme.surface
    }
}

/// A solid status circle with a white SF Symbol (pill, hourglass, checkmark).
struct StatusIcon: View {
    var symbol: String
    var size: CGFloat
    var tint: Color = Theme.blush

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: .circle)
    }
}

/// Tiny upper-case caption ("RIGHT NOW").
struct WidgetCaption: View {
    var text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Small coloured capsule label.
struct WidgetChip: View {
    var text: String
    var symbol: String?
    var tint: Color
    var fill: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(fill, in: .capsule)
    }
}
