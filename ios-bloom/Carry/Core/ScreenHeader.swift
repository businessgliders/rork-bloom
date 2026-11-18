import SwiftUI

/// The top of every tab and pushed page: no navigation bar; content starts at the safe area + 16 with a
/// 44 pt title row whose round button (+, back, settings) is vertically centred on the title.
enum ScreenHeader {
    /// Content top below the safe area.
    static let top: CGFloat = 16
    /// Height of the title row (and the round buttons in it).
    static let row: CGFloat = 44
}

/// The large-title row: optional leading back button, a 30 pt bold title, then trailing items.
struct ScreenTitleRow<Accessory: View, Trailing: View>: View {
    var title: String
    var onBack: (() -> Void)? = nil
    var backIdentifier = "screen-back"
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                RoundBackButton(identifier: backIdentifier, action: onBack)
            }
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.dayText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            accessory
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: .infinity, minHeight: ScreenHeader.row, alignment: .leading)
    }
}

extension ScreenTitleRow where Accessory == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil, backIdentifier: String = "screen-back",
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, onBack: onBack, backIdentifier: backIdentifier, accessory: { EmptyView() }, trailing: trailing)
    }
}

/// The 44 pt round button face used in title rows.
struct RoundIconLabel: View {
    var systemName: String
    var tint: Color = Theme.daySecondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: ScreenHeader.row, height: ScreenHeader.row)
            .background(Theme.dayCard, in: .circle)
            .contentShape(.circle)
    }
}

/// Back for pushed pages (the navigation bar is hidden there). The edge swipe still works.
struct RoundBackButton: View {
    var identifier = "screen-back"
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            RoundIconLabel(systemName: "chevron.left", tint: Theme.dayText)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Back")
        .accessibilityIdentifier(identifier)
    }
}
