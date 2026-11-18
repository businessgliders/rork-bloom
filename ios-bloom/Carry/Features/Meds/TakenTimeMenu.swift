import SwiftUI

/// Board 18: the small menu anchored to a check circle when the dose is logged away from its planned time.
/// "On time" (planned, rose tint, first) · "Just now" · "Another time…" (inline full-day wheel with its own confirm).
/// Tapping outside cancels. A quiet "Skip today" sits at the bottom.
/// Board 20: the same menu logs a meal (planned = the meal's end, no skip). `plannedStart` shows the
/// "On time" row as the planned span ("7:00–7:45 PM, as planned"); picking it still logs `planned`.
/// Sized by its host (`anchoredMenu`): fills the width it is given, text wraps, never truncates.
struct TakenTimeMenu: View {
    var planned: Date
    var plannedStart: Date?
    var question: String
    var wheelLabel: String = "Taken at"
    var onPick: (Date) -> Void
    var onSkip: (() -> Void)?

    init(planned: Date, plannedStart: Date? = nil, question: String, wheelLabel: String = "Taken at", onPick: @escaping (Date) -> Void, onSkip: (() -> Void)? = nil) {
        self.planned = planned
        self.plannedStart = plannedStart
        self.question = question
        self.wheelLabel = wheelLabel
        self.onPick = onPick
        self.onSkip = onSkip
    }

    init(instance: DoseInstance, question: String, onPick: @escaping (Date) -> Void, onSkip: @escaping () -> Void) {
        self.init(planned: instance.scheduledAt, question: question, onPick: onPick, onSkip: onSkip)
    }

    @State private var another = false
    @State private var time: Date = .now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cal: Calendar { PregnancyMath.calendar }
    private var isToday: Bool { cal.isDate(planned, inSameDayAs: .now) }

    /// Start of that day up to now (or the end of that day for a past day).
    private var range: ClosedRange<Date> {
        let start = cal.startOfDay(for: planned)
        let end = max(start, min(Date.now, PregnancyMath.addDays(1, to: start).addingTimeInterval(-60)))
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.daySecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                if planned <= .now {
                    option(title: "On time", detail: "\(plannedText), as planned",
                           highlighted: true, id: "taken-on-time") { onPick(planned) }
                }
                if isToday {
                    option(title: "Just now", detail: DayList.clock(.now), highlighted: false, id: "taken-just-now") {
                        onPick(.now)
                    }
                }
                option(title: "Another time\u{2026}", detail: nil, highlighted: another, id: "taken-another") {
                    Haptics.select()
                    time = min(max(planned, range.lowerBound), range.upperBound)
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.88)) {
                        another.toggle()
                    }
                }
                if another {
                    VStack(spacing: 6) {
                        DatePicker(wheelLabel, selection: $time, in: range, displayedComponents: .hourAndMinute)
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

            if let onSkip {
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
            } else {
                Spacer().frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dayCard)
    }

    /// "7:45 PM", or the planned span "7:00 – 7:45 PM" when a start is given.
    private var plannedText: String {
        guard let plannedStart, plannedStart < planned else { return DayList.clock(planned) }
        return (plannedStart..<planned).formatted(.interval.hour().minute())
    }

    private func option(title: String, detail: String?, highlighted: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(highlighted ? Theme.rose : Theme.dayText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(highlighted ? Theme.rose.opacity(0.85) : Theme.daySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(highlighted ? Theme.roseTint : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(id)
    }
}
