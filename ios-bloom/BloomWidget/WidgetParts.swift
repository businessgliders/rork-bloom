import SwiftUI
import WidgetKit

/// Cream canvas with a soft peach and blush glow, Bloom's widget atmosphere.
struct WidgetCanvas: View {
    var glow: Color = Theme.peachSoft

    var body: some View {
        ZStack {
            Theme.canvas
            GeometryReader { proxy in
                Circle()
                    .fill(glow)
                    .frame(width: proxy.size.width * 0.9)
                    .position(x: proxy.size.width * 1.0, y: -proxy.size.height * 0.05)
                Circle()
                    .fill(Theme.blushSoft.opacity(0.7))
                    .frame(width: proxy.size.width * 0.55)
                    .position(x: -proxy.size.width * 0.05, y: proxy.size.height * 1.05)
            }
        }
    }
}

/// A medication or baby-size emoji on a soft organic blob.
struct EmojiBlob: View {
    var emoji: String
    var size: CGFloat
    var style: AnyShapeStyle
    var seed: Int = 3

    init(emoji: String, size: CGFloat, fill: Color = Theme.peachSoft, seed: Int = 3) {
        self.init(emoji: emoji, size: size, style: AnyShapeStyle(fill), seed: seed)
    }

    init(emoji: String, size: CGFloat, style: AnyShapeStyle, seed: Int = 3) {
        self.emoji = emoji
        self.size = size
        self.style = style
        self.seed = seed
    }

    var body: some View {
        ZStack {
            BlobShape(seed: seed).fill(style)
            Text(emoji).font(.system(size: size * 0.52))
        }
        .frame(width: size, height: size)
    }
}

/// Tiny upper-case caption ("RIGHT NOW").
struct WidgetCaption: View {
    var text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.6)
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
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(fill, in: .capsule)
    }
}
