import SwiftUI

/// Board 20: a meal's check. Dashed green ring; once eaten, a soft green fill with a green check
/// (lighter than the solid medication check so the two never read the same).
struct MealCheckCircle: View {
    var done: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let green = Color(red: 0x5E / 255, green: 0x8A / 255, blue: 0x5A / 255)
    static let tint = Color(red: 0xE1 / 255, green: 0xEC / 255, blue: 0xD9 / 255)

    var body: some View {
        ZStack {
            Circle()
                .fill(done ? Self.tint : .clear)
            Circle()
                .strokeBorder(Self.green, style: StrokeStyle(lineWidth: 1.5, dash: done ? [] : [3.2, 2.6]))
                .opacity(done ? 0 : 1)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Self.green)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 30, height: 30)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.7), value: done)
    }
}

/// The inline card under a meal row when the meal ran into a no-food rule. Taker's phone only.
struct MealClashCard: View {
    var clash: MealClash
    var medicationName: String
    var onMove: () -> Void
    var onKeep: () -> Void

    private static let fill = Color(red: 0xF7 / 255, green: 0xE1 / 255, blue: 0xD8 / 255)

    private var hasFit: Bool { clash.to != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clash.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.terraText)
                .fixedSize(horizontal: false, vertical: true)
            Text(clash.sentence)
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(Theme.dayText)
                .fixedSize(horizontal: false, vertical: true)

            if let target = clash.target {
                VStack(spacing: 0) {
                    change(label: medicationName, from: clash.from, to: target)
                    Rectangle().fill(Theme.dayDivider).frame(height: 1)
                    change(label: "No food until", from: clash.noFoodUntilBefore, to: clash.noFoodUntilAfter)
                }
                .background(Color.white, in: .rect(cornerRadius: 12, style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: hasFit ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(clash.fitLine)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(hasFit ? Theme.greenText : Theme.terraText)

            HStack(spacing: 10) {
                if let target = clash.target {
                    Button {
                        if hasFit { Haptics.success() } else { Haptics.warning() }
                        onMove()
                    } label: {
                        Text("Move to \(ScheduleEngine.clock(target))")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BloomSoftButtonStyle(tint: hasFit ? .white : Theme.terraText,
                                                      fill: hasFit ? Theme.rose : .white))
                    .accessibilityIdentifier("meal-clash-move")
                }
                Button {
                    Haptics.select()
                    onKeep()
                } label: {
                    Text(hasFit ? "Keep \(ScheduleEngine.clock(clash.from))" : "Keep")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.dayText, fill: .white))
                .accessibilityIdentifier("meal-clash-keep")
            }

            Text("Today only · your routine doesn't change")
                .font(.system(size: 12))
                .foregroundStyle(Theme.daySecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .background(Self.fill, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meal-clash-card")
    }

    private func change(label: String, from: Int, to: Int?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.daySecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(ScheduleEngine.clock(from))
                .font(.system(size: 14))
                .foregroundStyle(Theme.dayMuted)
                .strikethrough(to != nil && to != from, color: Theme.dayMuted)
            if let to, to != from {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dayMuted)
                Text(ScheduleEngine.clock(to))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}
