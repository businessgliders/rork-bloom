import SwiftUI
import UIKit

/// Bloom's design tokens: system backgrounds, SF Pro, one deep-rose accent and
/// solid status colours. Every colour adapts to light and dark mode and every
/// text pairing below has been checked for at least 4.5:1 contrast.
///
/// Each hue has two roles:
/// - the base token (`blush`, `coral`, `sage`, `peach`) is a *fill* that keeps
///   white text at 4.5:1 or better in both modes;
/// - the `…Deep` token is for *text and icons* on the system backgrounds.
enum Theme {
    // Canvas & surfaces (native inset-grouped look)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let surfaceMuted = Color(uiColor: .tertiarySystemFill)

    // Text
    static let text = Color(uiColor: .label)
    /// Secondary text, darker than the system grey so it stays at 4.5:1 on grouped backgrounds.
    static let textSecondary = Color(light: 0x6C6C70, dark: 0xAEAEB2)

    // Fills (white text on top stays ≥ 4.5:1)
    static let blush = Color(light: 0xB42D55, dark: 0xCC3D66)      // accent: primary actions, current item
    static let coral = Color(light: 0xC4312A, dark: 0xD03A33)      // no food
    static let sage = Color(light: 0x1E7B3A, dark: 0x278445)       // food OK, done
    static let peach = Color(light: 0xA85400, dark: 0xB35F00)      // wake / bed, AI
    static let butter = Color(light: 0xA85400, dark: 0xB35F00)

    // Text / icon colours on system backgrounds
    static let blushDeep = Color(light: 0xB42D55, dark: 0xFF7A9C)
    static let coralDeep = Color(light: 0xC4312A, dark: 0xFF6961)
    static let sageDeep = Color(light: 0x1E7B3A, dark: 0x4CD07D)
    static let peachDeep = Color(light: 0xA85400, dark: 0xFFA24D)

    // Quiet tints behind status text (the matching …Deep text stays ≥ 4.5:1)
    static let blushSoft = Color(light: 0xF7E4EA, dark: 0x3A1F28)
    static let peachSoft = Color(light: 0xFBEBDC, dark: 0x3B2A1A)
    static let sageSoft = Color(light: 0xE3F1E6, dark: 0x1D3324)
    static let coralSoft = Color(light: 0xFBE5E3, dark: 0x3D201E)
    static let butterSoft = Color(light: 0xFBEBDC, dark: 0x3B2A1A)

    static let ringTrack = Color(uiColor: .systemFill)
    static let separator = Color(uiColor: .separator)

    static let cardRadius: CGFloat = 12
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
    /// SF Pro at a Dynamic Type text style. Heavy weights are capped at bold
    /// so the hierarchy comes from size, not weight.
    static func bloom(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let capped: Font.Weight = (weight == .heavy || weight == .black) ? .bold : weight
        return .system(style, weight: capped)
    }
}

// MARK: - Surfaces

/// A flat grouped-section surface, the same shape as an inset-grouped list row.
struct CardBackground: ViewModifier {
    var fill: Color = Theme.surface
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension View {
    func bloomCard(fill: Color = Theme.surface, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(fill: fill, padding: padding))
    }
}

// MARK: - Buttons

/// Filled accent button for the one primary action on a screen.
struct BloomPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.blush
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bloom(.body, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color(uiColor: .secondaryLabel))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(
                isEnabled ? tint : Color(uiColor: .tertiarySystemFill),
                in: .rect(cornerRadius: 12, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Plain accent-coloured text button for secondary actions.
struct BloomSoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.blushDeep
    /// Kept for source compatibility; secondary buttons have no fill.
    var fill: Color = .clear
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bloom(.body, weight: .regular))
            .foregroundStyle(isEnabled ? tint : Color(uiColor: .tertiaryLabel))
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
