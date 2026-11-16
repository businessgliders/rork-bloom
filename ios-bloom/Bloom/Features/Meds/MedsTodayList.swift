import SwiftUI

/// The day as one simple list (board 1): time · dot · name · check circle.
/// Meal and "No food until …" rows have no control. Taken rows are muted with a filled green check.
/// Tap a time: inline wheel, then the rule check with Just today / Every day. Tap a name: the medication sheet.
/// Tap the circle to log; long-press it for Now / Planned time / Pick a time / Skip. The list always scrolls.
struct MedsTodayList: View {
    var instances: [DoseInstance]
    var meals: [ScheduleMeal]
    var day: Date
    /// Whose routine the meals belong to.
    var owner: MedOwner
    /// Future days are read-only.
    var canLog: Bool
    /// Today only: draws the Now line and projects overdue food windows from now.
    var now: Date?
    var actions: DoseActions
    var onOpenMedication: (Medication) -> Void = { _ in }

    @Environment(AppStore.self) private var store
    @State private var picker: InlinePicker?

    fileprivate enum Entry: Identifiable {
        case dose(DoseInstance)
        case noFood(NoFoodWindow)
        case meal(ScheduleMeal, start: Date)
        case now(Date)

        var id: String {
            switch self {
            case .dose(let i): "dose-\(i.id)"
            case .noFood(let w): "nofood-\(w.id)"
            case .meal(let m, _): "meal-\(m.id)"
            case .now: "now"
            }
        }

        var time: Date {
            switch self {
            case .dose(let i): i.anchor
            case .noFood(let w): w.start
            case .meal(_, let start): start
            case .now(let d): d
            }
        }

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
        list += meals.map { .meal($0, start: $0.time.date(on: day)) }
        func stableSort(_ items: [Entry]) -> [Entry] {
            items.enumerated().sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
        }
        list = stableSort(list)
        if let now, let first = list.first.map(key)?.0, let last = list.last.map(key)?.0, now > first, now < last {
            list.append(.now(now))
            list = stableSort(list)
        }
        return list
    }

    /// The doses as they'd be with the time being picked or proposed, so the no-food rows move live.
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

    private func panelAnchor(_ entries: [Entry]) -> (String, ScheduleChange)? {
        guard let change = store.scheduleChange, case .row(let id) = change.placement,
              PregnancyMath.calendar.isDate(change.date, inSameDayAs: day) else { return nil }
        for entry in entries {
            switch entry {
            case .dose(let i) where i.medication.id == id && i.medication.owner == change.owner:
                return (entry.id, change)
            case .meal(let m, _) where m.id == id && change.owner == owner:
                return (entry.id, change)
            default: continue
            }
        }
        return nil
    }

    var body: some View {
        let entries = entries
        let panel = panelAnchor(entries)
        DayCard {
            if entries.isEmpty {
                Text("Nothing planned on this day.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0, !isNow(entry), !isNow(entries[index - 1]) {
                    DayDivider()
                }
                row(entry)
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
        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                   value: instances.map { "\($0.id)\($0.anchor.timeIntervalSince1970)\($0.status?.rawValue ?? "")" })
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: picker?.entryID)
        .animation(.easeOut(duration: 0.2), value: picker?.time)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.scheduleChange?.id)
        .accessibilityIdentifier("meds-day-list")
    }

    private func isNow(_ entry: Entry) -> Bool {
        if case .now = entry { return true }
        return false
    }

    // MARK: Rows

    private func pendingMinutes(_ id: UUID) -> Int? {
        guard let change = store.scheduleChange, change.kind != .review,
              Calendar.current.isDate(change.date, inSameDayAs: day),
              let t = change.times[id], let old = change.original[id], t != old else { return nil }
        return t
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .dose(let instance):
            doseRow(instance, entryID: entry.id)
        case .noFood(let window):
            DayRow(time: DayList.clock(window.start), dot: Theme.terraDot,
                   name: "No food until \(shortClock(window.end))",
                   muted: now.map { window.end <= $0 } ?? false,
                   nameColor: (now.map { window.end <= $0 } ?? false) ? nil : Theme.terraText)
                .accessibilityIdentifier("today-nofood")
        case .meal(let meal, let start):
            let movable = canMove(meal, start: start)
            DayRow(time: DayList.clock(start), dot: Theme.greenDot, name: meal.name,
                   muted: now.map { start < $0 } ?? false,
                   timeColor: picker?.entryID == entry.id ? Theme.rose : nil,
                   timeAction: movable ? { openMovePicker(entryID: entry.id, id: meal.id, owner: owner, isMeal: true, at: start) } : nil,
                   identifier: "meal-\(meal.name)")
                .accessibilityIdentifier("today-meal-\(meal.name)")
        case .now:
            NowRule()
        }
    }

    /// "3:00" for whole-hour-free times in the board's short style ("No food until 3:00").
    private func shortClock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    private func doseRow(_ instance: DoseInstance, entryID: String) -> some View {
        let med = instance.medication
        let movable = canMove(instance)
        let correctable = canLog && instance.isTaken
        let shown = previewInstances.first { $0.id == instance.id }?.anchor ?? instance.anchor
        let editing = picker?.entryID == entryID
        let timeAction: (() -> Void)? = movable
            ? { openMovePicker(entryID: entryID, id: med.id, owner: med.owner, isMeal: false, at: instance.anchor) }
            : correctable ? { openLogPicker(entryID: entryID, instance: instance) } : nil
        return DayRow(
            time: DayList.clock(shown),
            dot: instance.isTaken ? Theme.greenDot : (instance.isSkipped ? Theme.neutralDot : Theme.rose),
            name: med.shortName,
            muted: !instance.isPending,
            timeColor: editing || shown != instance.anchor ? Theme.rose : nil,
            timeAction: timeAction,
            nameAction: { Haptics.tap(); onOpenMedication(med) },
            identifier: med.shortName
        ) {
            if canLog { check(instance, entryID: entryID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-row-\(med.shortName)")
    }

    /// Tap: taken now (or undo). Long-press: Now / Planned time / Pick a time / Skip.
    private func check(_ instance: DoseInstance, entryID: String) -> some View {
        let med = instance.medication
        let nowTime = PregnancyMath.calendar.isDate(instance.scheduledAt, inSameDayAs: .now) ? Date.now : instance.scheduledAt
        return Button {
            if instance.isPending { actions.taken(instance, nowTime) } else { actions.undo(instance) }
        } label: {
            CheckCircle(state: instance.isTaken ? .taken : (instance.isSkipped ? .skipped : .open))
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if instance.isPending {
                Button { actions.taken(instance, nowTime) } label: { Label("Taken now", systemImage: "checkmark.circle") }
                if instance.scheduledAt <= .now {
                    Button { actions.taken(instance, instance.scheduledAt) } label: {
                        Label("At planned time · \(DayList.clock(instance.scheduledAt))", systemImage: "clock")
                    }
                }
                if let before = store.takenTimeBeforeUndo(instance) {
                    Button { actions.taken(instance, before) } label: {
                        Label("At \(DayList.clock(before)) (before undo)", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                Button { openLogPicker(entryID: entryID, instance: instance) } label: {
                    Label("Pick a time…", systemImage: "clock.arrow.circlepath")
                }
                Divider()
                Button { actions.skip(instance) } label: { Label("Skip today", systemImage: "forward.end") }
            } else {
                if instance.isTaken {
                    Button { openLogPicker(entryID: entryID, instance: instance) } label: {
                        Label("Change taken time…", systemImage: "clock.arrow.circlepath")
                    }
                }
                Button(role: .destructive) { actions.undo(instance) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
        }
        .accessibilityLabel(instance.isPending ? "Mark \(med.shortName) taken" : "Undo \(med.shortName)")
        .accessibilityIdentifier("today-check-\(med.shortName)")
    }

    private func minutes(_ date: Date) -> Int {
        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Only today's medications Bloom plans, not yet logged, can move.
    private func canMove(_ instance: DoseInstance) -> Bool {
        isToday && canLog && instance.isPending && instance.medication.managed && store.hasRoutine(instance.medication.owner)
    }

    private func canMove(_ meal: ScheduleMeal, start: Date) -> Bool {
        guard let now, canLog, store.hasRoutine(owner) else { return false }
        return start > now
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
        if picker?.entryID == entryID, case .log = picker?.mode { picker = nil; return }
        let upper = logRange(instance, now: .now).upperBound
        let start = min(instance.log?.takenAt ?? store.takenTimeBeforeUndo(instance) ?? (isToday ? .now : instance.scheduledAt), upper)
        picker = InlinePicker(entryID: entryID, mode: .log(instance), time: start, upper: upper)
    }

    private func logRange(_ instance: DoseInstance, now: Date) -> ClosedRange<Date> {
        let start = PregnancyMath.calendar.startOfDay(for: instance.scheduledAt)
        let end = max(start, min(now, PregnancyMath.addDays(1, to: start).addingTimeInterval(-60)))
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
        case .log(let instance): logRange(instance, now: value.upper ?? .now)
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
                    .buttonStyle(BloomSoftButtonStyle(tint: Theme.daySecondary, fill: Theme.creamBox))
                Spacer()
                Text(value.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.daySecondary)
                Spacer()
                Button(value.doneLabel) { commit(value, range: range) }
                    .buttonStyle(BloomSoftButtonStyle(tint: Theme.rose, fill: Theme.roseTint))
                    .accessibilityIdentifier("picker-done")
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func commit(_ value: InlinePicker, range: ClosedRange<Date>) {
        let time = min(max(picker?.time ?? value.time, range.lowerBound), range.upperBound)
        picker = nil
        switch value.mode {
        case .log(let instance):
            if instance.isTaken { actions.changeTaken(instance, time) } else { actions.taken(instance, time) }
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
        case move(id: UUID, owner: MedOwner, isMeal: Bool)
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
    var upper: Date?

    var title: String {
        switch mode {
        case .move: "New time"
        case .log: "Taken at"
        }
    }

    var doneLabel: String {
        switch mode {
        case .move: "Check"
        case .log(let instance): instance.isTaken ? "Save" : "Log"
        }
    }
}
