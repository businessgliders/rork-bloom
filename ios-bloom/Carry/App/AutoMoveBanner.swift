import SwiftUI

/// "Progesterone AM moved to 9:45 AM tomorrow, 10 h after last night's dose."
/// Shown on the next open after a late dose moved the next one by itself. Undo puts it back.
struct AutoMoveBanner: View {
    let notice: AutoMoveNotice
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .frame(width: 32, height: 32)
                .background(Theme.surface.opacity(0.7), in: .circle)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.bloom(.footnote, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Haptics.select()
                onUndo()
            } label: {
                Text("Undo")
                    .font(.bloom(.footnote, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Theme.surface, in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.rose)
            .accessibilityIdentifier("auto-move-undo")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("auto-move-dismiss")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(Theme.roseTint, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.rose.opacity(0.18)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("auto-move-banner")
    }
}
