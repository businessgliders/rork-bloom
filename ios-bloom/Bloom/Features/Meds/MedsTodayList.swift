import SwiftUI

/// The day as one time-ordered list: medications (with a checkmark), "8:00–8:30 · No food" rows and meals.
/// Today: tap an upcoming medication's or meal's time to pick a new one on an inline wheel.
/// Changes show inline under the row; nothing is saved until she chooses. Rows never capture
/// drags, so the list always scrolls.
struct MedsTodayList: View {
    var instances: [DoseInstance]
    var meals: [ScheduleMeal]
    var day: Date
    /// Whose routine the meals belong to.
    var owner: MedOwner
    /// Future days are read-only.
    var canLog: Bool
    /// Today only: draws the now line and projects overdue food windows from now.
    var now: Date?
    var actions: DoseActions

    @Environment(AppStore.self) private var store
    @State private var picker: InlinePicker?

    fileprivate enum Entry: Identifiable {
        case dose(DoseInstance)
        case noFood(NoFoodWindow)
        case meal(ScheduleMeal, start: Date, end: Date)
        case now(Date)

        var id: String {
            switch self {
            case .dose(let i): "dose-\(i.id)"
            case .noFood(let w): "nofood-\(w.id)"
            case .meal(let m, _, _): "meal-\(m.id)"
            case .now: "now"
            }
        }

        var time: Date {
            switch self {
            case .dose(let i): i.anchor
            case .noFood(let w): w.start
            case .meal(_, let start, _): start
            case .now(let d): d
            }
        }

        /// Ties: "before" windows end at their dose, "after" windows start right below it, meals come last.
        var rank: Int {
            switch self {
            case .noFood(let w): w.part == .after ? 3 : 0
            case .now: 1
            case .dose: 2
            case .meal: 4
            }
        }
    }

    private var isToday: Bool { now != nil }

    private var entries: [Entry] {
        let preview = previewInstances
        // A dose being moved sits at its new time so its no-food rows stay around it.
        var previewAnchor: [String: Date] = [:]
        for (original, shown) in zip(instances, preview) where shown.anchor != original.anchor {
            previewAnchor[original.id] = shown.anchor
        }
        func key(_ e: Entry) -> (Date, Int) {
            if case .dose(let i) = e, let t = previewAnchor[i.id] { return (t, e.rank) }
            return (e.time, e.rank)
        }
        var list: [Entry] = instances.map { .dose($0) }
        list += MedsEngine.noFoodWindows(for: preview, now: now).map { .noFood($0) }
        list += meals.map { meal in
            let start = meal.time.date(on: day)
            return .meal(meal, start: start, end: start.addingTimeInterval(Double(meal.durationMinutes) * 60))
        }
        list.sort { key($0) < key($1) }
        if let now, !list.isEmpty, let first = list.first.map(key)?.0, let last = list.last.map(key)?.0, now > first, now < last {
            list.append(.now(now))
            list.sort { key($0) < key($1) }
        }
        return list
    }

    /// The doses as they'd be with the time being picked or proposed, so the no-food rows move live
    /// while the wheel spins, and the "after" row counts from the taken time being logged.
    private var previewInstances: [DoseInstance] {
        instances.map { instance in
            let med = instance.medication
            if let picker {
                switch picker.mode {
                case .move(let id, _, false) where id == med.id && instance.isPending:
                    return DoseInstance(medication: med, scheduledAt: picker.time, log: nil)
                case .log(let target) where target.id == instance.id:
                    var log = instance.log ?? DoseLog(medicationID: med.id, scheduledAt: instance.scheduledAt, status: .taken)
                    log.status = .taken
                    log.takenAt = picker.time
                    return DoseInstance(medication: med, scheduledAt: instance.scheduledAt, log: log)
                default: break
                }
            }
            if instance.isPending, let m = pendingMinutes(med.id) {
                let start = PregnancyMath.calendar.startOfDay(for: day)
                return DoseInstance(medication: med, scheduledAt: start.addingTimeInterval(Double(m) * 60), log: nil)
            }
            return instance
        }
    }

    /// Medications that break a rule today, by id.
    private var warnings: Set<UUID> {
        let owners = Set(instances.filter { $0.medication.managed }.map(\.medication.owner))
        var ids = Set<UUID>()
        for o in owners {
            for v in store.dayViolations(o, on: day) { ids.insert(v.rule.subjectID) }
        }
        return ids
    }

    /// The change panel for this list, and the row it sits under.
    private func panelAnchor(_ entries: [Entry]) -> (String, ScheduleChange)? {
        guard let change = store.scheduleChange, case .row(let id) = change.placement,
              PregnancyMath.calendar.isDate(change.date, inSameDayAs: day) else { return nil }
        for entry in entries {
            switch entry {
            case .dose(let i) where i.medication.id == id && i.medication.owner == change.owner:
                return (entry.id, change)
            case .meal(let m, _, _) where m.id == id && change.owner == owner:
                return (entry.id, change)
            default: continue
            }
        }
        return nil
    }

    var body: some View {
        let entries = entries
        let warnings = warnings
        let panel = panelAnchor(entries)
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Nothing planned on this day.")
                    .font(.bloom(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0, !isNow(entry), !isNow(entries[index - 1]) {
                    Divider().padding(.leading, 88)
                }
                row(entry, warnings: warnings)
                    .transition(.opacity)
                if let picker, picker.entryID == entry.id {
                    pickerRow(picker)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let panel, panel.0 == entry.id {
                    ScheduleChangePanel(change: panel.1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .id(ScheduleChangePanel.scrollID)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                   value: instances.map { "\($0.id)\($0.anchor.timeIntervalSince1970)\($0.status?.rawValue ?? "")" })
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: picker?.entryID)
        .animation(.easeOut(duration: 0.2), value: picker?.time)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.scheduleChange?.id)
    }

    private func isNow(_ entry: Entry) -> Bool {
        if case .now = entry { return true }
        return false
    }

    // MARK: Rows

    /// While the panel waits for her choice, a dose it would move shows its proposed time next to the old one.
    private func pendingMinutes(_ id: UUID) -> Int? {
        guard let change = store.scheduleChange, change.kind != .review,
              Calendar.current.isDate(change.date, inSameDayAs: day),
              let t = change.times[id], let old = change.original[id], t != old else { return nil }
        return t
    }

    /// The time a dose's label shows while the wheel spins or a change is pending, when it differs from now.
    private func previewMinutes(_ instance: DoseInstance) -> Int? {
        guard let shown = previewInstances.first(where: { $0.medication.id == instance.medication.id }),
              shown.anchor != instance.anchor else { return nil }
        return minutes(shown.anchor)
    }

    @ViewBuilder
    private func row(_ entry: Entry, warnings: Set<UUID>) -> some View {
        switch entry {
        case .dose(let instance):
            let med = instance.medication
            let movable = canMove(instance)
            TodayDoseRow(
                instance: instance,
                canLog: canLog,
                actions: actions,
                previewMinutes: previewMinutes(instance),
                isEditingTime: picker?.entryID == entry.id && isMovePicker,
                hasWarning: instance.isPending && warnings.contains(med.id),
                onTimeTap: movable ? { openMovePicker(entryID: entry.id, id: med.id, owner: med.owner, isMeal: false, at: instance.anchor) } : nil,
                onWarning: { review(instance) },
                onPickTime: { openLogPicker(entryID: entry.id, instance: instance) }
            )
        case .noFood(let window):
            SpanRow(start: window.start, end: window.end, title: window.title,
                    detail: window.part == .after && window.isConfirmed ? "Counted from when it was taken" : "",
                    tint: Theme.coralDeep, bar: Theme.coral)
                .accessibilityIdentifier("today-nofood")
        case .meal(let meal, let start, let end):
            let movable = canMove(meal, start: start)
            SpanRow(start: start, end: end, title: meal.name,
                    detail: "Food OK", tint: Theme.sageDeep, bar: Theme.sage,
                    isEditingTime: picker?.entryID == entry.id,
                    onTimeTap: movable ? { openMovePicker(entryID: entry.id, id: meal.id, owner: owner, isMeal: true, at: start) } : nil)
                .accessibilityIdentifier("today-meal-\(meal.name)")
        case .now(let date):
            NowLine(date: date)
        }
    }

    private func minutes(_ date: Date) -> Int {
        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Only today's medications Bloom plans, not yet logged, can move.
    private func canMove(_ instance: DoseInstance) -> Bool {
        isToday && canLog && instance.isPending && instance.medication.managed && store.hasRoutine(instance.medication.owner)
    }

    /// Meals still to come today.
    private func canMove(_ meal: ScheduleMeal, start: Date) -> Bool {
        guard let now, canLog, store.hasRoutine(owner) else { return false }
        return start > now
    }

    private var isMovePicker: Bool {
        if case .move = picker?.mode { return true }
        return false
    }

    private func review(_ instance: DoseInstance) {
        Haptics.tap()
        picker = nil
        store.proposeDayChange(owner: instance.medication.owner, day: day, edit: .review, placement: .row(instance.medication.id))
    }

    // MARK: Inline time picker

    private func openMovePicker(entryID: String, id: UUID, owner: MedOwner, isMeal: Bool, at date: Date) {
        Haptics.select()
        store.scheduleChange = nil
        if picker?.entryID == entryID { picker = nil; return }
        picker = InlinePicker(entryID: entryID, mode: .move(id: id, owner: owner, isMeal: isMeal), time: date)
    }

    private func openLogPicker(entryID: String, instance: DoseInstance) {
        Haptics.select()
        store.scheduleChange = nil
        let upper = logRange(instance).upperBound
        let start = min(instance.log?.takenAt ?? (isToday ? .now : instance.scheduledAt), upper)
        picker = InlinePicker(entryID: entryID, mode: .log(instance), time: start)
    }

    private func logRange(_ instance: DoseInstance) -> ClosedRange<Date> {
        let start = PregnancyMath.calendar.startOfDay(for: instance.scheduledAt)
        let end = max(start, min(Date.now, PregnancyMath.addDays(1, to: start).addingTimeInterval(-60)))
        return start...end
    }

    private func moveRange(_ mode: InlinePicker.Mode) -> ClosedRange<Date> {
        let start = PregnancyMath.calendar.startOfDay(for: day)
        guard case .move(_, let owner, let isMeal) = mode, let state = store.dayState(owner, on: day) else {
            return start...PregnancyMath.addDays(1, to: start).addingTimeInterval(-60)
        }
        let range = isMeal ? state.wake...max(state.bed, state.wake) : state.range
        return start.addingTimeInterval(Double(range.lowerBound) * 60)...start.addingTimeInterval(Double(range.upperBound) * 60)
    }

    private func pickerRow(_ value: InlinePicker) -> some View {
        let range: ClosedRange<Date> = switch value.mode {
        case .log(let instance): logRange(instance)
        case .move: moveRange(value.mode)
        }
        return VStack(spacing: 4) {
            DatePicker(value.title, selection: Binding(
                get: { min(max(picker?.time ?? value.time, range.lowerBound), range.upperBound) },
                set: { picker?.time = $0 }
            ), in: range, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxHeight: 150)
            .clipped()
            HStack {
                Button("Cancel") { picker = nil }
                    .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary))
                Spacer()
                Text(value.title)
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(value.doneLabel) { commit(value, range: range) }
                    .buttonStyle(BloomSoftButtonStyle())
                    .font(.bloom(.body, weight: .semibold))
                    .accessibilityIdentifier("picker-done")
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func commit(_ value: InlinePicker, range: ClosedRange<Date>) {
        let time = min(max(picker?.time ?? value.time, range.lowerBound), range.upperBound)
        picker = nil
        switch value.mode {
        case .log(let instance):
            actions.taken(instance, time)
        case .move(let id, let owner, let isMeal):
            let m = ScheduleEngine.roundNearest(minutes(time))
            let edit: DayEdit = isMeal ? .meal(id, m) : .dose(id, m)
            store.proposeDayChange(owner: owner, day: day, edit: edit, placement: .row(id))
        }
    }
}

// MARK: - State

private struct InlinePicker: Equatable {
    enum Mode: Equatable {
        /// Change a planned time (a medication or a meal).
        case move(id: UUID, owner: MedOwner, isMeal: Bool)
        /// When she actually took it.
        case log(DoseInstance)

        static func == (a: Mode, b: Mode) -> Bool {
            switch (a, b) {
            case let (.move(x, _, _), .move(y, _, _)): x == y
            case let (.log(x), .log(y)): x.id == y.id
            default: false
            }
        }
    }

    var entryID: String
    var mode: Mode
    var time: Date

    var title: String {
        switch mode {
        case .move: "New time"
        case .log: "Taken at"
        }
    }

    var doneLabel: String {
        switch mode {
        case .move: "Move"
        case .log: "Log"
        }
    }
}

// MARK: - Rows

private let timeWidth: CGFloat = 72

private func clock(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// "8:00–8:30 · No food" / "12:30–13:00 · Lunch"
private struct SpanRow: View {
    var start: Date
    var end: Date
    var title: String
    var detail: String
    var tint: Color
    var bar: Color
    var isEditingTime = false
    var onTimeTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            timeLabel
            RoundedRectangle(cornerRadius: 2)
                .fill(bar)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.bloom(.subheadline, weight: .heavy))
                    .foregroundStyle(tint)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.bloom(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(clock(start)) to \(clock(end))")
    }

    @ViewBuilder
    private var timeLabel: some View {
        let label = VStack(alignment: .trailing, spacing: 0) {
            EditableTime(text: clock(start), editable: onTimeTap != nil, isEditing: isEditingTime)
                .foregroundStyle(onTimeTap == nil ? Theme.textSecondary : Theme.blushDeep)
            Text(clock(end))
                .foregroundStyle(Theme.textSecondary)
                .padding(.trailing, onTimeTap == nil ? 0 : EditableTime.chevronSpace)
        }
        .font(.bloom(.caption, weight: .bold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
        .frame(width: timeWidth, alignment: .trailing)
        .frame(minHeight: 44)
        if let onTimeTap {
            Button(action: onTimeTap) { label }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Change \(title) time")
        } else {
            label
        }
    }
}

private struct TodayDoseRow: View {
    var instance: DoseInstance
    var canLog: Bool
    var actions: DoseActions
    /// The change panel proposes moving this dose here; the old time shows faint above it.
    var previewMinutes: Int?
    /// Its inline time wheel is open.
    var isEditingTime = false
    var hasWarning: Bool
    var onTimeTap: (() -> Void)?
    var onWarning: () -> Void
    var onPickTime: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        let med = instance.medication
        HStack(spacing: 12) {
            timeLabel

            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(med.shortName)
                        .font(.bloom(.headline, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .strikethrough(instance.isSkipped, color: Theme.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if hasWarning {
                        Button(action: onWarning) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.coralDeep)
                                .frame(width: 28, height: 28)
                                .contentShape(.rect)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("\(med.shortName) breaks a rule. Show fixes")
                        .accessibilityIdentifier("today-warning-\(med.shortName)")
                    }
                }
                Text(statusText)
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)

            if canLog { check }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, canLog ? 6 : 14)
        .background(isEditingTime ? Theme.blushSoft.opacity(0.5) : .clear)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-row-\(med.shortName)")
    }

    private var barColor: Color {
        if instance.isTaken { return Theme.sage }
        if instance.isSkipped { return Theme.surfaceMuted }
        return Theme.blush
    }

    @ViewBuilder
    private var timeLabel: some View {
        let label = VStack(alignment: .trailing, spacing: 0) {
            if let previewMinutes {
                Text(clock(instance.anchor))
                    .font(.bloom(.caption, weight: .semibold))
                    .strikethrough(true, color: Theme.textSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.trailing, onTimeTap == nil ? 0 : EditableTime.chevronSpace)
                EditableTime(text: ScheduleEngine.clock(previewMinutes), editable: onTimeTap != nil, isEditing: isEditingTime)
                    .font(.bloom(.subheadline, weight: .heavy))
                    .foregroundStyle(Theme.blushDeep)
                    .transition(.opacity)
            } else {
                EditableTime(text: clock(instance.anchor), editable: onTimeTap != nil, isEditing: isEditingTime)
                    .font(.bloom(.subheadline, weight: .heavy))
                    .foregroundStyle(instance.isPending ? (onTimeTap == nil ? Theme.text : Theme.blushDeep) : Theme.textSecondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: timeWidth, alignment: .trailing)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .animation(.easeOut(duration: 0.15), value: previewMinutes)
        if let onTimeTap {
            Button(action: onTimeTap) { label }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Change \(instance.medication.shortName) time, \(clock(instance.anchor))")
                .accessibilityHint("Opens a time wheel under the row")
                .accessibilityIdentifier("today-time-\(instance.medication.shortName)")
        } else {
            label
        }
    }

    /// Tap: taken now (or undo). Long-press: Now / Planned / Pick a time / Skip.
    private var check: some View {
        let med = instance.medication
        return Menu {
            if instance.isPending {
                Button { actions.taken(instance, nowTime) } label: { Label("Now", systemImage: "checkmark.circle") }
                if instance.scheduledAt <= .now {
                    Button { actions.taken(instance, instance.scheduledAt) } label: {
                        Label("Planned (\(clock(instance.scheduledAt)))", systemImage: "clock")
                    }
                }
                Button(action: onPickTime) { Label("Pick a time…", systemImage: "clock.arrow.circlepath") }
                Divider()
                Button { actions.skip(instance) } label: { Label("Skip", systemImage: "forward.end") }
            } else {
                if instance.isTaken {
                    Button(action: onPickTime) { Label("Change taken time…", systemImage: "clock.arrow.circlepath") }
                }
                Button { actions.undo(instance) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
            Divider()
            Button { actions.edit(med) } label: { Label("Edit medication", systemImage: "pencil") }
        } label: {
            Image(systemName: instance.isTaken ? "checkmark.circle.fill" : (instance.isSkipped ? "minus.circle.fill" : "circle"))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(instance.isTaken ? Theme.sage : (instance.isSkipped ? Theme.textSecondary.opacity(0.6) : Theme.blush))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        } primaryAction: {
            if instance.isPending { actions.taken(instance, nowTime) } else { actions.undo(instance) }
        }
        .accessibilityLabel(instance.isPending ? "Mark \(med.shortName) taken" : "Undo \(med.shortName)")
        .accessibilityHint("Touch and hold for more times")
        .accessibilityIdentifier("today-check-\(med.shortName)")
    }

    /// "Now" on a past day means the planned time.
    private var nowTime: Date {
        PregnancyMath.calendar.isDate(instance.scheduledAt, inSameDayAs: .now) ? .now : instance.scheduledAt
    }

    private var statusText: String {
        let planned = clock(instance.scheduledAt)
        var parts: [String] = []
        if instance.isTaken, let takenAt = instance.log?.takenAt {
            let taken = clock(takenAt)
            parts.append(taken == planned ? "Taken" : "Taken \(taken) · planned \(planned)")
        } else if instance.isSkipped {
            parts.append("Skipped · planned \(planned)")
        } else {
            if let dose = store.detailLine(instance.medication) { parts.append(dose) }
            parts.append(instance.medication.foodSummary)
        }
        if !instance.isPending, let by = store.loggedByLine(instance.log) { parts.append(by) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if instance.isTaken { return Theme.sageDeep }
        if instance.isSkipped { return Theme.textSecondary }
        return instance.medication.foodRule == .emptyStomach ? Theme.coralDeep : Theme.textSecondary
    }
}

/// A time she can tap to change: the time plus a small chevron, so it reads as editable.
private struct EditableTime: View {
    static let chevronSpace: CGFloat = 11
    var text: String
    var editable: Bool
    var isEditing: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if editable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .rotationEffect(.degrees(isEditing ? 180 : 0))
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isEditing)
    }
}

private struct NowLine: View {
    var date: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("Now")
                .font(.bloom(.caption, weight: .heavy))
                .foregroundStyle(Theme.blushDeep)
                .frame(width: timeWidth, alignment: .trailing)
            Circle().fill(Theme.blushDeep).frame(width: 7, height: 7)
            Rectangle().fill(Theme.blushDeep.opacity(0.6)).frame(height: 1.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .accessibilityLabel("Now, \(clock(date))")
    }
}
