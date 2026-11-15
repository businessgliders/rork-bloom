import SwiftUI
import UIKit

/// Bloom's design tokens. Every colour adapts to light and dark mode.
enum Theme {
    // Canvas & surfaces
    static let canvas = Color(light: 0xFBF5EE, dark: 0x221A19)
    static let surface = Color(light: 0xFFFFFF, dark: 0x2E2422)
    static let surfaceMuted = Color(light: 0xF6EEE6, dark: 0x382C29)

    // Text
    static let text = Color(light: 0x3A2C2A, dark: 0xF6ECE6)
    static let textSecondary = Color(light: 0x9A8A84, dark: 0xB5A49D)

    // Accents
    static let blush = Color(light: 0xEE9AA6, dark: 0xF0A4AF)
    static let peach = Color(light: 0xF6B892, dark: 0xF4BE9C)
    static let sage = Color(light: 0x9DBF9E, dark: 0xA3C6A4)
    static let coral = Color(light: 0xF08A7E, dark: 0xF2968B)
    static let butter = Color(light: 0xF5D98B, dark: 0xF2D88F)

    // Deeper accents for text / icons on soft tints (contrast)
    static let blushDeep = Color(light: 0xD4677A, dark: 0xF4AEB8)
    static let sageDeep = Color(light: 0x5C8C60, dark: 0xB4D6B5)
    static let coralDeep = Color(light: 0xD45F4F, dark: 0xF7A99F)
    static let peachDeep = Color(light: 0xD98450, dark: 0xF7C8A8)

    // Soft tints
    static let blushSoft = Color(light: 0xFBE3E4, dark: 0x4A2E31)
    static let peachSoft = Color(light: 0xFDEBDD, dark: 0x4A3428)
    static let sageSoft = Color(light: 0xDDEEDB, dark: 0x2F3D2F)
    static let coralSoft = Color(light: 0xFBDCD6, dark: 0x4C2C28)
    static let butterSoft = Color(light: 0xFCF1D2, dark: 0x463D26)

    static let ringTrack = Color(light: 0xF1E5DA, dark: 0x3B2F2C)

    static let cardRadius: CGFloat = 28
    static let confettiColors: [Color] = [blush, peach, sage, butter, coral]
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Font {
    /// Large rounded type used across Bloom.
    static func bloom(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

// MARK: - Surfaces

struct CardBackground: ViewModifier {
    var fill: Color = Theme.surface
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(0.14), radius: 18, y: 8)
    }
}

extension View {
    func bloomCard(fill: Color = Theme.surface, padding: CGFloat = 20) -> some View {
        modifier(CardBackground(fill: fill, padding: padding))
    }
}

// MARK: - Buttons

struct BloomPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.blush
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bloom(.title3, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(tint.opacity(isEnabled ? 1 : 0.4), in: .capsule)
            .shadow(color: tint.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct BloomSoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.blushDeep
    var fill: Color = Theme.blushSoft

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bloom(.headline, weight: .bold))
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(fill, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
