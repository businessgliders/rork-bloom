import SwiftUI

/// "Move" on an upcoming medication: a few big times that already keep every rule, then Just today / Every day.
/// "Other time…" opens the wheel and goes through the usual rule check under the row.
struct MoveDoseSheet: View {
    var instance: DoseInstance
    var day: Date
    /// A time from the wheel: checked under the row like any other move.
    var onOtherTime: (Int) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var plan: MovePlan?
    @State private var chosen: MoveOption?
    @State private var showWheel = false
    @State private var wheelTime = Date()

    private var med: Medication { instance.medication }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan {
                        header(plan)
                        optionsGrid(plan)
                        otherTime(plan)
                        if let chosen { scopeButtons(chosen, plan: plan) }
                    } else {
                        CarrySpinner(size: 30).frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
            .navigationTitle("Move \(med.shortName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: chosen)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showWheel)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            plan = store.movePlan(owner: med.owner, day: day, medicationID: med.id)
            wheelTime = instance.anchor
        }
    }

    // MARK: Parts

    private func header(_ plan: MovePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MedBadge(medication: med, size: 44, fill: Theme.blushSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.shortName)
                        .font(.bloom(.title3, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text("Planned \(ScheduleEngine.clock(plan.current))")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !plan.limits.isEmpty {
                Label(plan.limits, systemImage: "checklist")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textCaption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("move-limits")
            }
            if !plan.dependents.isEmpty {
                Label("\(plan.dependents.formatted(.list(type: .and))) will move too, so the gap stays", systemImage: "link")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.peachDeep)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("move-dependents")
            }
        }
    }

    @ViewBuilder
    private func optionsGrid(_ plan: MovePlan) -> some View {
        if plan.options.isEmpty {
            Text("No other time today keeps every rule. Try Other time… to see what's in the way.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Times that keep every rule")
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(plan.options) { option in
                        optionButton(option, plan: plan)
                    }
                }
            }
        }
    }

    private func optionButton(_ option: MoveOption, plan: MovePlan) -> some View {
        let selected = chosen?.minutes == option.minutes
        let diff = option.minutes - plan.current
        return Button {
            Haptics.select()
            chosen = option
            showWheel = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ScheduleEngine.clock(option.minutes))
                    .font(.bloom(.title2, weight: .heavy))
                    .monospacedDigit()
                Text("\(ScheduleEngine.duration(abs(diff))) \(diff > 0 ? "later" : "earlier")")
                    .font(.bloom(.caption, weight: .semibold))
                ForEach(option.alongside, id: \.id) { other in
                    Label("\(other.name) \(ScheduleEngine.clock(other.minutes))", systemImage: "link")
                        .font(.bloom(.caption))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(selected ? .white : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(14)
            .background(selected ? Theme.roseButton : Theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? .clear : Theme.blush.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(ScheduleEngine.clock(option.minutes))\(option.alongside.isEmpty ? "" : ", " + option.alongside.map { "\($0.name) moves to \(ScheduleEngine.clock($0.minutes))" }.joined(separator: ", "))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("move-option-\(ScheduleEngine.clock(option.minutes))")
    }

    @ViewBuilder
    private func otherTime(_ plan: MovePlan) -> some View {
        Button {
            Haptics.tap()
            chosen = nil
            showWheel.toggle()
        } label: {
            Label("Other time…", systemImage: "clock")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BloomSoftButtonStyle())
        .accessibilityIdentifier("move-other-time")
        if showWheel {
            VStack(spacing: 8) {
                DatePicker("New time", selection: $wheelTime, in: wheelRange, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxHeight: 160)
                    .clipped()
                Button {
                    let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: wheelTime)
                    let m = ScheduleEngine.roundNearest((c.hour ?? 0) * 60 + (c.minute ?? 0))
                    dismiss()
                    onOtherTime(m)
                } label: {
                    Text("Check \(wheelTime.formatted(date: .omitted, time: .shortened))")
                }
                .buttonStyle(BloomPrimaryButtonStyle())
                .accessibilityIdentifier("move-check-time")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var wheelRange: ClosedRange<Date> {
        let start = PregnancyMath.calendar.startOfDay(for: day)
        guard let s = store.dayState(med.owner, on: day) else {
            return start...start.addingTimeInterval(1439 * 60)
        }
        return start.addingTimeInterval(Double(s.range.lowerBound) * 60)...start.addingTimeInterval(Double(s.range.upperBound) * 60)
    }

    private func scopeButtons(_ option: MoveOption, plan: MovePlan) -> some View {
        VStack(spacing: 10) {
            Button {
                store.applyMove(owner: med.owner, day: day, option: option, medicationID: med.id, scope: .today)
                dismiss()
            } label: {
                Text("Just today")
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .accessibilityIdentifier("move-today")
            Button {
                store.applyMove(owner: med.owner, day: day, option: option, medicationID: med.id, scope: .forward)
                dismiss()
            } label: {
                Text(ScheduleChangePanel.everyLabel(plan.routineName))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BloomSoftButtonStyle())
            .accessibilityIdentifier("move-forward")
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
