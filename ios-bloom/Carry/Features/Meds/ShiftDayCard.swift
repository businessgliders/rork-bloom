import SwiftUI

/// "Shift my day": two big buttons move everything not taken yet 15 minutes earlier or later, gaps kept.
/// The list shows the new times right away; nothing is saved until Done → Just today / Every day.
struct ShiftDayCard: View {
    var owner: MedOwner
    var day: Date
    @Environment(AppStore.self) private var store

    private var change: ScheduleChange? {
        guard let c = store.scheduleChange, c.kind == .shift, c.owner == owner,
              PregnancyMath.calendar.isDate(c.date, inSameDayAs: day) else { return nil }
        return c
    }

    var body: some View {
        let change = change
        let delta = change?.shift ?? 0
        let bounds = store.shiftBounds(owner, day: day)
        if bounds != nil || change != nil {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    stepButton(minutes: -15, delta: delta, bounds: bounds)
                    VStack(spacing: 3) {
                        Text("Shift my day")
                            .font(.bloom(.headline, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        Text(label(delta))
                            .font(.bloom(.footnote, weight: delta == 0 ? .regular : .semibold))
                            .foregroundStyle(delta == 0 ? Theme.textSecondary : Theme.peachDeep)
                            .multilineTextAlignment(.center)
                            .contentTransition(.numericText(value: Double(delta)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    stepButton(minutes: 15, delta: delta, bounds: bounds)
                }
                if let change {
                    if change.asked {
                        ScheduleChangePanel(change: change)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        HStack(spacing: 10) {
                            Button("Put back") { store.discardChange() }
                                .buttonStyle(CarrySoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
                                .accessibilityIdentifier("shift-put-back")
                            Button {
                                Haptics.tap()
                                store.scheduleChange?.asked = true
                            } label: {
                                Text("Done").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(CarrySoftButtonStyle(tint: .white, fill: Theme.peachButton))
                            .accessibilityIdentifier("shift-done")
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .bloomCard(fill: Theme.surface.opacity(0.94), padding: 14)
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: change?.asked)
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: change == nil)
            .animation(.snappy, value: delta)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shift-my-day")
        }
    }

    private func label(_ delta: Int) -> String {
        if delta == 0 { return "Running early or late? Move everything not taken yet." }
        return "Everything \(ScheduleEngine.duration(abs(delta))) \(delta > 0 ? "later" : "earlier") · gaps kept"
    }

    private func stepButton(minutes: Int, delta: Int, bounds: ClosedRange<Int>?) -> some View {
        let next = delta + minutes
        // Bounds are worked out from the current plan, so a pending shift is measured from zero.
        let enabled = bounds.map { $0.contains(next) } ?? (next == 0)
        return Button {
            Haptics.select()
            store.proposeShift(owner, day: day, by: next)
        } label: {
            VStack(spacing: -2) {
                Text(minutes < 0 ? "−15" : "+15")
                    .font(.bloom(.title3, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text("min")
                    .font(.bloom(.caption2, weight: .bold))
            }
            .foregroundStyle(enabled ? Theme.peachDeep : Theme.textSecondary.opacity(0.5))
            .frame(width: 64, height: 64)
            .background(enabled ? Theme.peachSoft : Theme.surfaceMuted, in: .circle)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .accessibilityLabel(minutes < 0 ? "15 minutes earlier" : "15 minutes later")
        .accessibilityIdentifier(minutes < 0 ? "shift-earlier" : "shift-later")
    }
}
