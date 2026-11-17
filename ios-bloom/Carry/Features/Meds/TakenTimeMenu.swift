import SwiftUI

/// Board 18: the small menu anchored to a check circle when the dose is logged away from its planned time.
/// "On time" (planned, rose tint, first) · "Just now" · "Another time…" (inline full-day wheel with its own confirm).
/// Tapping outside cancels. A quiet "Skip today" sits at the bottom.
struct TakenTimeMenu: View {
    var instance: DoseInstance
    var question: String
    var onPick: (Date) -> Void
    var onSkip: () -> Void

    @State private var another = false
    @State private var time: Date = .now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cal: Calendar { PregnancyMath.calendar }
    private var isToday: Bool { cal.isDate(instance.scheduledAt, inSameDayAs: .now) }

    /// Start of that day up to now (or the end of that day for a past day).
    private var range: ClosedRange<Date> {
        let start = cal.startOfDay(for: instance.scheduledAt)
        let end = max(start, min(Date.now, PregnancyMath.addDays(1, to: start).addingTimeInterval(-60)))
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.daySecondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                if instance.scheduledAt <= .now {
                    option(title: "On time", detail: "\(DayList.clock(instance.scheduledAt)), as planned",
                           highlighted: true, id: "taken-on-time") { onPick(instance.scheduledAt) }
                }
                if isToday {
                    option(title: "Just now", detail: DayList.clock(.now), highlighted: false, id: "taken-just-now") {
                        onPick(.now)
                    }
                }
                option(title: "Another time\u{2026}", detail: nil, highlighted: another, id: "taken-another") {
                    Haptics.select()
                    time = min(max(instance.scheduledAt, range.lowerBound), range.upperBound)
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.88)) {
                        another.toggle()
                    }
                }
                if another {
                    VStack(spacing: 6) {
                        DatePicker("Taken at", selection: $time, in: range, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(height: 130)
                            .clipped()
                            .accessibilityIdentifier("taken-wheel")
                        Button {
                            onPick(min(max(time, range.lowerBound), range.upperBound))
                        } label: {
                            Text("Log \(DayList.clock(time))")
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BloomSoftButtonStyle(tint: Theme.rose, fill: Theme.roseTint))
                        .accessibilityIdentifier("taken-confirm")
                    }
                    .padding(.horizontal, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 6)

            Rectangle().fill(Theme.dayDivider).frame(height: 1).padding(.top, 8)
            Button {
                onSkip()
            } label: {
                Text("Skip today")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("taken-skip")
        }
        .frame(width: 264)
        .background(Theme.dayCard)
        .presentationBackground(Theme.dayCard)
    }

    private func option(title: String, detail: String?, highlighted: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(highlighted ? Theme.rose : Theme.dayText)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(highlighted ? Theme.rose.opacity(0.85) : Theme.daySecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(highlighted ? Theme.roseTint : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(id)
    }
}
