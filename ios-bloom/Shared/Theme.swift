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
    static let textSecondary = Color(light: 0x796963, dark: 0xB5A49D)
    /// Small caption and time text on the Lock Screen and widgets (7:1 or better).
    static let textCaption = Color(light: 0x5E4E49, dark: 0xD4C5BE)

    // Accents
    static let blush = Color(light: 0xE88C9B, dark: 0xF0A4AF)
    static let peach = Color(light: 0xF6B892, dark: 0xF4BE9C)
    static let sage = Color(light: 0x86B488, dark: 0x92C094)
    static let coral = Color(light: 0xEE7A6C, dark: 0xF28779)
    static let butter = Color(light: 0xF5D98B, dark: 0xF2D88F)

    // Deeper accents for text / icons on soft tints (contrast)
    static let blushDeep = Color(light: 0xB63D52, dark: 0xF4AEB8)
    static let sageDeep = Color(light: 0x3C6F40, dark: 0xB4D6B5)
    static let coralDeep = Color(light: 0xA7392A, dark: 0xF7A99F)
    static let peachDeep = Color(light: 0xA35729, dark: 0xF7C8A8)

    // Soft tints
    static let blushSoft = Color(light: 0xFBE3E4, dark: 0x4A2E31)
    static let peachSoft = Color(light: 0xFDEBDD, dark: 0x4A3428)
    static let sageSoft = Color(light: 0xD3EBD0, dark: 0x2F4530)
    static let coralSoft = Color(light: 0xFAD2CA, dark: 0x552E29)
    static let butterSoft = Color(light: 0xFCF1D2, dark: 0x463D26)

    // Filled buttons with white text (4.5:1 or better in both modes)
    static let roseButton = Color(light: 0xC44E5E, dark: 0xC44E5E)
    static let peachButton = Color(light: 0xB25F2C, dark: 0xB25F2C)
    static let sageButton = Color(light: 0x468348, dark: 0x468348)
    static let coralButton = Color(light: 0xCD4838, dark: 0xCD4838)

    /// Rose accent on the dark undo toast (Theme.text capsule).
    static let toastAccent = Color(light: 0xF4AEB8, dark: 0xA33246)

    static let ringTrack = Color(light: 0xF1E5DA, dark: 0x3B2F2C)

    static let cardRadius: CGFloat = 28

    // MARK: Day list (boards, 2026-11-16)
    static let dayCanvas = Color(light: 0xFBF5EE, dark: 0x1F1917)
    static let dayCard = Color(light: 0xFFFFFF, dark: 0x2A2220)
    static let dayDivider = Color(light: 0xEFE6DC, dark: 0x3A302C)
    static let dayText = Color(light: 0x3A2C2A, dark: 0xF4EAE4)
    static let daySecondary = Color(light: 0x6F5F59, dark: 0xC2B2AA)
    static let dayMuted = Color(light: 0x8A7A73, dark: 0x9C8C85)
    static let rose = Color(light: 0xA8385A, dark: 0xE58AA2)
    static let roseTint = Color(light: 0xF6E3E6, dark: 0x43262E)
    static let greenDot = Color(light: 0x5E8A5A, dark: 0x8DB688)
    static let greenCheck = Color(light: 0x4A7347, dark: 0x6E9E69)
    static let greenTint = Color(light: 0xE1ECD9, dark: 0x26352A)
    static let greenText = Color(light: 0x35592F, dark: 0xB9D8B2)
    static let terraDot = Color(light: 0xB5502F, dark: 0xE08A68)
    static let terraTint = Color(light: 0xF7E1D8, dark: 0x42281F)
    static let terraText = Color(light: 0x8F3D22, dark: 0xF0A98C)
    static let neutralDot = Color(light: 0xC9B8A8, dark: 0x6E625B)
    static let creamBox = Color(light: 0xF8F0E6, dark: 0x332926)
    static let dayRadius: CGFloat = 20
    static let confettiColors: [Color] = [blush, peach, sage, butter, coral]
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension Color {
    /// This colour with its light or dark value picked now. Widgets and Live
    /// Activities are archived before the system shows them, so they fix each
    /// token to the colour scheme they were rendered in instead of relying on
    /// a dynamic colour being resolved later.
    func fixed(_ scheme: ColorScheme) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        return Color(uiColor: UIColor(self).resolvedColor(with: traits))
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
    /// Bloom's type: regular SF Pro at the system text styles.
    static func bloom(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, weight: weight)
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
    var tint: Color = Theme.roseButton
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
