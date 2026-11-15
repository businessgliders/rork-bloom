import SwiftUI

/// Actions a dose row can trigger.
struct DoseActions {
    var taken: (DoseInstance) -> Void
    var takenAt: (DoseInstance) -> Void
    var skip: (DoseInstance) -> Void
    var undo: (DoseInstance) -> Void
    var edit: (Medication) -> Void
}

/// The day's timeline: doses at their anchor time with merged No food / Food OK blocks,
/// grouped into Morning, Afternoon and Evening.
struct MedsTimelineView: View {
    var instances: [DoseInstance]
    /// Future days are read-only.
    var canLog: Bool
    /// Today only: overdue, unlogged doses show their window as "if taken now".
    var now: Date?
    var actions: DoseActions

    var body: some View {
        let sections = MedsEngine.sections(for: instances, now: now)
        VStack(alignment: .leading, spacing: 22) {
            if sections.isEmpty {
                Text("No doses on this day.")
                    .font(.bloom(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .bloomCard()
            }
            ForEach(sections, id: \.slot) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Label(section.slot.title, systemImage: section.slot.symbol)
                        .font(.bloom(.title3, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .labelStyle(SlotLabelStyle(tint: tint(for: section.slot)))
                        .padding(.leading, 4)

                    VStack(spacing: 8) {
                        ForEach(section.entries) { entry in
                            row(entry)
                                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: instances.map { "\($0.id)\($0.anchor.timeIntervalSince1970)\($0.status?.rawValue ?? "")" })
    }

    @ViewBuilder
    private func row(_ entry: MedsTimelineEntry) -> some View {
        switch entry {
        case .dose(let instance):
            DoseRow(instance: instance, canLog: canLog, actions: actions)
        case .noFood(let window):
            NoFoodBlock(window: window)
        case .foodOK(let start, let until):
            FoodOKBlock(start: start, until: until)
        }
    }

    private func tint(for slot: DaySlot) -> Color {
        switch slot {
        case .morning: Theme.peach
        case .afternoon: Theme.butter
        case .evening: Theme.blush
        }
    }
}

private struct SlotLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: .circle)
            configuration.title
        }
    }
}

// MARK: - Dose row

private struct DoseRow: View {
    var instance: DoseInstance
    var canLog: Bool
    var actions: DoseActions
    @Environment(AppStore.self) private var store

    var body: some View {
        let med = instance.medication
        HStack(spacing: 12) {
            TimeColumn(date: instance.anchor, faded: instance.isSkipped)

            // Long names ("Levothyroxine") on narrow screens: drop the emoji badge rather than
            // hyphenating the name mid-word.
            ViewThatFits(in: .horizontal) {
                card(med: med, showEmoji: true, nameFits: true)
                card(med: med, showEmoji: false, nameFits: false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func card(med: Medication, showEmoji: Bool, nameFits: Bool) -> some View {
            HStack(spacing: 12) {
                if showEmoji {
                    MedBadge(medication: med, size: 46, fill: emojiFill, faded: instance.isSkipped)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(med.shortName)
                        .font(.bloom(.headline, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .strikethrough(instance.isSkipped, color: Theme.textSecondary)
                        .lineLimit(nameFits ? nil : 2)
                        .minimumScaleFactor(nameFits ? 1 : 0.8)
                        .fixedSize(horizontal: nameFits, vertical: false)
                    if let detail = store.detailLine(med) {
                        Text(detail)
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(statusText)
                        .font(.bloom(.footnote, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 4)

                if canLog {
                    checkButton
                    menu
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .padding(.trailing, canLog ? 4 : 14)
            .background(Theme.surface, in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(0.1), radius: 10, y: 4)
    }

    private var emojiFill: Color {
        if instance.isTaken { return Theme.sageSoft }
        if instance.isSkipped { return Theme.surfaceMuted }
        return Theme.blushSoft
    }

    private var statusText: String {
        let planned = instance.scheduledAt.formatted(date: .omitted, time: .shortened)
        if let takenAt = instance.log?.takenAt, instance.isTaken {
            let taken = takenAt.formatted(date: .omitted, time: .shortened)
            let base = taken == planned ? "Taken \(taken)" : "Taken \(taken) · planned \(planned)"
            return store.loggedByLine(instance.log).map { "\(base) · \($0)" } ?? base
        }
        if instance.isSkipped {
            return "Skipped · planned \(planned)" + (store.loggedByLine(instance.log).map { " · \($0)" } ?? "")
        }
        return instance.medication.foodSummary
    }

    private var statusColor: Color {
        if instance.isTaken { return Theme.sageDeep }
        if instance.isSkipped { return Theme.textSecondary }
        return instance.medication.foodRule == .emptyStomach ? Theme.coralDeep : Theme.textSecondary
    }

    private var checkButton: some View {
        Button {
            if instance.isPending { actions.taken(instance) } else { actions.undo(instance) }
        } label: {
            Image(systemName: instance.isTaken ? "checkmark.circle.fill" : (instance.isSkipped ? "minus.circle.fill" : "circle"))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(instance.isTaken ? Theme.sage : (instance.isSkipped ? Theme.textSecondary : Theme.blush))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(instance.isPending ? "Mark \(instance.medication.shortName) taken" : "Undo \(instance.medication.shortName)")
    }

    private var menu: some View {
        Menu {
            DoseMenuItems(instance: instance, actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(instance.medication.shortName)")
    }
}

/// The actions shared by list rows and day-view markers.
struct DoseMenuItems: View {
    var instance: DoseInstance
    var actions: DoseActions

    var body: some View {
        if instance.isPending {
            Button { actions.taken(instance) } label: { Label("Taken now", systemImage: "checkmark.circle") }
            Button { actions.takenAt(instance) } label: { Label("Taken at a different time…", systemImage: "clock.arrow.circlepath") }
            Button { actions.skip(instance) } label: { Label("Skip", systemImage: "forward.end") }
        } else {
            if instance.isTaken {
                Button { actions.takenAt(instance) } label: { Label("Change taken time…", systemImage: "clock.arrow.circlepath") }
            }
            Button { actions.undo(instance) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
        }
        Divider()
        Button { actions.edit(instance.medication) } label: { Label("Edit medication", systemImage: "pencil") }
    }
}

private struct TimeColumn: View {
    var date: Date
    var faded = false

    var body: some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.bloom(.caption, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 52, alignment: .trailing)
    }
}

// MARK: - Food blocks

private struct NoFoodBlock: View {
    var window: NoFoodWindow
    @Environment(\.medsPerson) private var person

    var body: some View {
        HStack(spacing: 12) {
            TimeColumn(date: window.start)
            HStack(spacing: 12) {
                Capsule()
                    .fill(Theme.coral)
                    .frame(width: 5)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No food \(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.coralDeep)
                    Text("\(window.isConfirmed ? "Counting from when \(PersonWording.took(person)) it" : "Planned · moves to when \(PersonWording.takes(person)) it") · \(window.reasons.joined(separator: " & "))")
                        .font(.bloom(.footnote))
                        .foregroundStyle(Theme.text)
                }
                Spacer(minLength: 0)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.coralDeep)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Theme.coralSoft, in: .rect(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FoodOKBlock: View {
    var start: Date
    var until: Date?

    var body: some View {
        HStack(spacing: 12) {
            TimeColumn(date: start)
            HStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 13, weight: .semibold))
                Text(until.map { "Food OK until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Food OK")
                    .font(.bloom(.subheadline, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.sageDeep)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Theme.sageSoft, in: .capsule)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Taken at a different time

struct TakenAtSheet: View {
    var instance: DoseInstance
    var onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var time: Date

    /// The taker's name when it's not the person holding the phone.
    private var person: String? {
        store.isShared && !store.isMine(instance.medication) ? store.takerName(instance.medication) : nil
    }

    init(instance: DoseInstance, onSave: @escaping (Date) -> Void) {
        self.instance = instance
        self.onSave = onSave
        let upper = min(Date.now, Self.dayEnd(for: instance.scheduledAt))
        _time = State(initialValue: min(instance.log?.takenAt ?? instance.scheduledAt, upper))
    }

    private static func dayEnd(for date: Date) -> Date {
        PregnancyMath.addDays(1, to: date).addingTimeInterval(-60)
    }

    private var range: ClosedRange<Date> {
        let start = PregnancyMath.calendar.startOfDay(for: instance.scheduledAt)
        let end = max(start, min(Date.now, Self.dayEnd(for: instance.scheduledAt)))
        return start...end
    }

    private let offsets = [0, 5, 10, 15, 30, 60]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    MedBadge(medication: instance.medication, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instance.medication.shortName)
                            .font(.bloom(.headline, weight: .semibold))
                        Text("Planned \(instance.scheduledAt.formatted(date: .omitted, time: .shortened))")
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Text("Food windows count from the time \(person ?? "you") actually took it.")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(offsets, id: \.self) { offset in
                            let date = instance.scheduledAt.addingTimeInterval(Double(offset) * 60)
                            let enabled = range.contains(date)
                            let selected = abs(time.timeIntervalSince(date)) < 30
                            Button {
                                Haptics.select()
                                time = date
                            } label: {
                                Text(offset == 0 ? "On time" : "+\(offset) min")
                                    .font(.bloom(.subheadline, weight: .semibold))
                                    .foregroundStyle(selected ? .white : Theme.blushDeep)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(selected ? Theme.blush : Theme.blushSoft, in: .capsule)
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(!enabled)
                            .opacity(enabled ? 1 : 0.4)
                        }
                    }
                }

                DatePicker("Taken at", selection: $time, in: range, displayedComponents: .hourAndMinute)
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)

                Spacer(minLength: 0)

                Button {
                    onSave(time)
                    dismiss()
                } label: {
                    Text("Save · taken \(time.formatted(date: .omitted, time: .shortened))")
                }
                .buttonStyle(BloomPrimaryButtonStyle())
            }
            .padding(24)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(person.map { "When did \($0) take it?" } ?? "When did you take it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
    }
}
