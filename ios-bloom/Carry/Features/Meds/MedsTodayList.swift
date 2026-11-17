import SwiftUI

/// The day as one simple list (board 1): time · dot · name · check circle.
/// Meal and "No food until …" rows have no control. Taken rows are muted with a filled green check.
/// Tap a medication's time (today or a later day): − / + in 5 min steps and a full-day wheel; once she stops, an inline
/// "Move … to …?" confirm (with the rule it would break, if any). Only Move changes that date; the routine stays.
/// Tap a meal time: inline wheel, then the rule check with Just today / Every day. Tap a name: the medication sheet.
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
    @Environment(\.revealInScroll) private var revealInScroll
    private static let doseMoveScrollID = "dose-move-editor"
    @State private var picker: InlinePicker?
    @State private var doseMove: DoseMove?
    @State private var settle: Task<Void, Never>?
    /// The row whose "When did you take it?" menu is open.
    @State private var logMenu: String?

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
                HStack(spacing: 12) {
                    CarryEmptyMark(size: 24)
                    Text("Nothing planned on this day.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.daySecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0, !isNow(entry), !isNow(entries[index - 1]) {
                    DayDivider()
                }
                row(entry)
                    .id(entry.id)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 6)
                    .animation(.easeOut(duration: 0.35).delay(Double(index) * 0.03), value: appeared)
                    .transition(.opacity)
                if let picker, picker.entryID == entry.id {
                    pickerRow(picker)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let doseMove, doseMove.entryID == entry.id {
                    doseMoveEditor(doseMove)
                        .id(Self.doseMoveScrollID)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        // Keep the steppers, wheel and confirm on screen as each one appears.
                        .onAppear { revealInScroll?(Self.doseMoveScrollID) }
                        .onChange(of: doseMove.wheel) { _, open in if open { revealInScroll?(Self.doseMoveScrollID) } }
                        .onChange(of: doseMove.check != nil) { _, shown in if shown { revealInScroll?(Self.doseMoveScrollID) } }
                }
                if case .meal(let meal, _) = entry {
                    ForEach(clashes(for: meal), id: \.id) { clash in
                        MealClashCard(
                            clash: clash,
                            medicationName: store.medicationNames[clash.medicationID] ?? "Medication",
                            onMove: { store.acceptMealClash(clash, owner: owner) },
                            onKeep: { store.keepMealClash(clash) }
                        )
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
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
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: doseMove?.entryID)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: doseMove?.wheel)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: doseMove?.check)
        .onDisappear { settle?.cancel() }
        .animation(.easeOut(duration: 0.2), value: picker?.time)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.scheduleChange?.id)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85),
                   value: store.mealClashes[owner]?.map(\.id) ?? [])
        .accessibilityIdentifier("meds-day-list")
        .onAppear {
            // Rows fade and rise once per launch, not on every tab switch.
            guard !appeared else { return }
            MedsTodayList.rowsHaveAppeared = true
            appeared = true
        }
    }

    /// Set after the first list appearance in this launch.
    static var rowsHaveAppeared = false
    @State private var appeared = MedsTodayList.rowsHaveAppeared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            let log = mealLogFor(meal)
            DayRow(time: DayList.clock(start), dot: Theme.greenDot, name: meal.name,
                   muted: log == nil && (now.map { start < $0 } ?? false),
                   timeColor: picker?.entryID == entry.id ? Theme.rose : nil,
                   timeAction: movable && log == nil ? { openMovePicker(entryID: entry.id, id: meal.id, owner: owner, isMeal: true, at: start) } : nil,
                   identifier: "meal-\(meal.name)",
                   subtitle: log.map { eatenCaption($0, meal: meal) },
                   subtitleColor: Theme.greenText) {
                if isCheckable(meal) { mealCheck(meal, log: log, entryID: entry.id) }
            }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today-meal-\(meal.name)")
        case .now:
            NowRule()
        }
    }

    /// "3:00" for whole-hour-free times in the board's short style ("No food until 3:00").
    /// In 24-hour locales the AM/PM-free style pads to "07:30", so use the list's own clock there.
    private func shortClock(_ date: Date) -> String {
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        return twelveHour
            ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
            : DayList.clock(date)
    }

    private func doseRow(_ instance: DoseInstance, entryID: String) -> some View {
        let med = instance.medication
        let movable = canMove(instance)
        let correctable = canLog && instance.isTaken
        let shown = previewInstances.first { $0.id == instance.id }?.anchor ?? instance.anchor
        let editing = picker?.entryID == entryID || doseMove?.entryID == entryID
        let timeAction: (() -> Void)? = movable
            ? { openDoseMove(entryID: entryID, instance: instance) }
            : correctable ? { openLogPicker(entryID: entryID, instance: instance) } : nil
        return DayRow(
            time: DayList.clock(shown),
            dot: instance.isTaken ? Theme.greenDot : (instance.isSkipped ? Theme.neutralDot : Theme.rose),
            name: med.shortName,
            muted: !instance.isPending,
            timeColor: editing || shown != instance.anchor ? Theme.rose : nil,
            timeAction: timeAction,
            nameAction: { Haptics.tap(); onOpenMedication(med) },
            identifier: med.shortName,
            dotBounce: instance.isTaken,
            subtitle: store.mealCaption(for: instance),
            subtitleColor: Theme.daySecondary
        ) {
            if canLog { check(instance, entryID: entryID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-row-\(med.shortName)")
    }

    /// Pending: a tap within 10 minutes of the planned time logs it as now; otherwise (or on long-press)
    /// a small "When did you take it?" menu opens on the circle. Logged: tap undoes, long-press corrects.
    @ViewBuilder
    private func check(_ instance: DoseInstance, entryID: String) -> some View {
        if instance.isPending {
            pendingCheck(instance, entryID: entryID)
        } else {
            loggedCheck(instance, entryID: entryID)
        }
    }

    private func pendingCheck(_ instance: DoseInstance, entryID: String) -> some View {
        let med = instance.medication
        let isOpen = Binding(get: { logMenu == entryID }, set: { if !$0, logMenu == entryID { logMenu = nil } })
        return CheckCircle(state: .open)
            .scaleEffect(logMenu == entryID ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: logMenu == entryID)
            .onTapGesture {
                let today = PregnancyMath.calendar.isDate(instance.scheduledAt, inSameDayAs: .now)
                if today, abs(Date.now.timeIntervalSince(instance.scheduledAt)) <= 600 {
                    actions.taken(instance, .now)
                } else {
                    openLogMenu(entryID)
                }
            }
            .onLongPressGesture(minimumDuration: 0.4) { openLogMenu(entryID) }
            .popover(isPresented: isOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                TakenTimeMenu(
                    instance: instance,
                    question: takenQuestion(med),
                    onPick: { time in
                        logMenu = nil
                        actions.taken(instance, time)
                    },
                    onSkip: {
                        logMenu = nil
                        actions.skip(instance)
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Mark \(med.shortName) taken")
            .accessibilityAction { openLogMenu(entryID) }
            .accessibilityIdentifier("today-check-\(med.shortName)")
    }

    // MARK: Meals (board 20)

    private func isCheckable(_ meal: ScheduleMeal) -> Bool {
        guard canLog, isToday else { return false }
        return store.checkableMeals(owner, on: day)[MealKind.of(meal.name)]?.id == meal.id
    }

    private func mealLogFor(_ meal: ScheduleMeal) -> MealLog? {
        guard isCheckable(meal) else { return nil }
        return store.mealLog(owner, on: day, kind: MealKind.of(meal.name))
    }

    private func clashes(for meal: ScheduleMeal) -> [MealClash] {
        guard isToday else { return [] }
        return (store.mealClashes[owner] ?? []).filter { $0.meal == meal.name }
    }

    private func mealEnd(_ meal: ScheduleMeal) -> Date {
        meal.time.date(on: day).addingTimeInterval(Double(meal.durationMinutes) * 60)
    }

    /// "Eaten 9:40 AM", or "Eaten 1:30 PM · planned 12:00" when it was more than 10 minutes off.
    private func eatenCaption(_ log: MealLog, meal: ScheduleMeal) -> String {
        let eaten = "Eaten \(DayList.clock(log.eatenAt))"
        guard abs(log.eatenAt.timeIntervalSince(mealEnd(meal))) > 600 else { return eaten }
        return "\(eaten) · planned \(shortClock(log.plannedAt ?? meal.time.date(on: day)))"
    }

    private func mealCheck(_ meal: ScheduleMeal, log: MealLog?, entryID: String) -> some View {
        let menuID = "mealcheck-\(entryID)"
        let isOpen = Binding(get: { logMenu == menuID }, set: { if !$0, logMenu == menuID { logMenu = nil } })
        let planned = mealEnd(meal)
        return MealCheckCircle(done: log != nil)
            .scaleEffect(logMenu == menuID ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: logMenu == menuID)
            .onTapGesture {
                if log != nil {
                    Haptics.select()
                    store.undoMeal(meal, owner: owner, day: day)
                } else if abs(Date.now.timeIntervalSince(planned)) <= 600 {
                    Haptics.success()
                    store.logMeal(meal, owner: owner, day: day, at: .now)
                } else {
                    openLogMenu(menuID)
                }
            }
            .onLongPressGesture(minimumDuration: 0.4) { openLogMenu(menuID) }
            .popover(isPresented: isOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                TakenTimeMenu(
                    planned: planned,
                    question: mealQuestion(meal),
                    wheelLabel: "Finished at",
                    onPick: { time in
                        logMenu = nil
                        Haptics.success()
                        store.logMeal(meal, owner: owner, day: day, at: time)
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(log == nil ? "Mark \(meal.name) eaten" : "Undo \(meal.name)")
            .accessibilityAction { if log == nil { openLogMenu(menuID) } else { store.undoMeal(meal, owner: owner, day: day) } }
            .accessibilityIdentifier("meal-check-\(meal.name)")
    }

    private func mealQuestion(_ meal: ScheduleMeal) -> String {
        let name = meal.name.lowercased()
        if !store.isShared || owner == store.viewerRole { return "When did you finish \(name)?" }
        return owner == .mom ? "When did she finish \(name)?" : "When did \(store.name(for: owner)) finish \(name)?"
    }

    private func openLogMenu(_ entryID: String) {
        Haptics.select()
        picker = nil
        closeDoseMove()
        logMenu = entryID
    }

    private func takenQuestion(_ med: Medication) -> String {
        if store.isMine(med) { return "When did you take it?" }
        return med.owner == .mom ? "When did she take it?" : "When did \(store.name(for: med.owner)) take it?"
    }

    private func loggedCheck(_ instance: DoseInstance, entryID: String) -> some View {
        let med = instance.medication
        return Button {
            actions.undo(instance)
        } label: {
            CheckCircle(state: instance.isTaken ? .taken : .skipped)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if instance.isTaken {
                Button { openLogPicker(entryID: entryID, instance: instance) } label: {
                    Label("Change taken time…", systemImage: "clock.arrow.circlepath")
                }
            }
            Button(role: .destructive) { actions.undo(instance) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
        }
        .accessibilityLabel("Undo \(med.shortName)")
        .accessibilityIdentifier("today-check-\(med.shortName)")
    }

    private func minutes(_ date: Date) -> Int {
        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Today or a later day: medications Carry plans, not yet logged, can move. Past days stay read-only.
    private func canMove(_ instance: DoseInstance) -> Bool {
        let cal = PregnancyMath.calendar
        let editableDay = cal.startOfDay(for: day) >= cal.startOfDay(for: store.now)
        return editableDay && instance.isPending && instance.medication.managed && store.hasRoutine(instance.medication.owner)
    }

    private func canMove(_ meal: ScheduleMeal, start: Date) -> Bool {
        guard let now, canLog, store.hasRoutine(owner) else { return false }
        return start > now
    }

    // MARK: Inline time picker

    private func openMovePicker(entryID: String, id: UUID, owner: MedOwner, isMeal: Bool, at date: Date) {
        Haptics.select()
        store.scheduleChange = nil
        closeDoseMove()
        if picker?.entryID == entryID { picker = nil; return }
        picker = InlinePicker(entryID: entryID, mode: .move(id: id, owner: owner, isMeal: isMeal), time: date)
    }

    private func openLogPicker(entryID: String, instance: DoseInstance) {
        Haptics.select()
        store.scheduleChange = nil
        closeDoseMove()
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

    // MARK: Moving a dose (this date only)

    private func openDoseMove(entryID: String, instance: DoseInstance) {
        Haptics.select()
        store.scheduleChange = nil
        picker = nil
        if doseMove?.entryID == entryID { closeDoseMove(); return }
        let m = Int(instance.anchor.timeIntervalSince(PregnancyMath.calendar.startOfDay(for: day)) / 60)
        let start = min(max(m, 0), 1439)
        settle?.cancel()
        doseMove = DoseMove(entryID: entryID, id: instance.medication.id, owner: instance.medication.owner,
                            name: instance.medication.shortName, original: start, minutes: start)
    }

    private func closeDoseMove() {
        settle?.cancel()
        doseMove = nil
    }

    /// Sets the new time; the confirm appears once she has stopped changing it for a moment.
    private func setDoseMinutes(_ m: Int) {
        guard var move = doseMove else { return }
        let clamped = min(max(m, 0), 1439)
        guard clamped != move.minutes else { return }
        move.minutes = clamped
        move.check = nil
        doseMove = move
        settle?.cancel()
        guard clamped != move.original else { return }
        settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let current = doseMove, current.minutes == clamped else { return }
            doseMove?.check = check(current)
        }
    }

    /// What the new time would do: the rules it breaks (her drag wording) and any dose that settles with it.
    private func check(_ move: DoseMove) -> DoseMove.Check {
        let preview = store.previewDayChange(owner: move.owner, day: day, edit: .dose(move.id, move.minutes))
        let names = store.medicationNames
        var reasons: [String] = []
        if let mine = preview?.broken[move.id] { reasons.append(mine) }
        for (id, reason) in (preview?.broken ?? [:]).sorted(by: { (names[$0.key] ?? "") < (names[$1.key] ?? "") }) where id != move.id {
            reasons.append("\(names[id] ?? "Medication") \(reason)")
        }
        let alongside = (preview?.moved ?? [:])
            .sorted { $0.value < $1.value }
            .map { "\(names[$0.key] ?? "Medication") moves to \(ScheduleEngine.clock($0.value))" }
        return DoseMove.Check(minutes: move.minutes, reasons: Array(reasons.prefix(2)), alongside: alongside)
    }

    private func doseMoveEditor(_ move: DoseMove) -> some View {
        let dayStart = PregnancyMath.calendar.startOfDay(for: day)
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                stepButton(icon: "minus", label: "5 minutes earlier", id: "move-minus") { setDoseMinutes((doseMove?.minutes ?? move.minutes) - 5) }
                    .disabled(move.minutes <= 0)
                Button {
                    Haptics.select()
                    doseMove?.wheel.toggle()
                } label: {
                    Text(ScheduleEngine.clock(move.minutes))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(move.minutes == move.original ? Theme.dayText : Theme.rose)
                        .contentTransition(.numericText(value: Double(move.minutes)))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(move.wheel ? Theme.roseTint : Theme.creamBox, in: .rect(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("New time, \(ScheduleEngine.clock(move.minutes))")
                .accessibilityHint("Opens a wheel for any time of day")
                .accessibilityIdentifier("move-time")
                stepButton(icon: "plus", label: "5 minutes later", id: "move-plus") { setDoseMinutes((doseMove?.minutes ?? move.minutes) + 5) }
                    .disabled(move.minutes >= 1439)
            }
            .animation(.snappy(duration: 0.2), value: move.minutes)

            if move.wheel {
                DatePicker("New time", selection: Binding(
                    get: { dayStart.addingTimeInterval(Double(doseMove?.minutes ?? move.minutes) * 60) },
                    set: { date in
                        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
                        setDoseMinutes((c.hour ?? 0) * 60 + (c.minute ?? 0))
                    }
                ), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxHeight: 150)
                .clipped()
                .accessibilityIdentifier("move-wheel")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let check = move.check, check.minutes == move.minutes {
                moveConfirm(move, check: check)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if move.minutes == move.original {
                Button("Cancel") {
                    Haptics.select()
                    closeDoseMove()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.daySecondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("move-close")
            } else {
                // Holds the confirm's place quietly while she is still choosing.
                Text("Stop to check this time")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }

    private func stepButton(icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.rose)
                .frame(width: 48, height: 48)
                .background(Theme.roseTint, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func moveConfirm(_ move: DoseMove, check: DoseMove.Check) -> some View {
        let warning = !check.reasons.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(check.reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.terraDot).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(reason)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.terraText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("move-reason")
            }
            Text("Move \(Text(move.name).bold()) to \(Text(ScheduleEngine.clock(move.minutes)).bold())?")
                .font(.system(size: 17))
                .monospacedDigit()
                .foregroundStyle(Theme.dayText)
                .fixedSize(horizontal: false, vertical: true)
            if !check.alongside.isEmpty {
                Text(check.alongside.joined(separator: " · "))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.daySecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only \(dayLabel). Your routine stays the same.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dayMuted)
            HStack(spacing: 10) {
                Button("Cancel") {
                    Haptics.select()
                    closeDoseMove()
                }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.daySecondary, fill: Theme.creamBox))
                .accessibilityIdentifier("move-cancel")
                Spacer(minLength: 0)
                Button {
                    let id = move.id, owner = move.owner, minutes = move.minutes
                    closeDoseMove()
                    if warning { Haptics.warning() }
                    store.moveDose(owner: owner, day: day, medicationID: id, to: minutes)
                } label: {
                    Label("Move", systemImage: warning ? "exclamationmark.triangle.fill" : "arrow.right")
                        .labelStyle(MoveLabelStyle(showIcon: warning))
                }
                .buttonStyle(BloomSoftButtonStyle(tint: warning ? Theme.terraText : Theme.rose,
                                                  fill: warning ? Theme.terraTint : Theme.roseTint))
                .accessibilityIdentifier("move-confirm")
            }
        }
        .padding(14)
        .background(warning ? Theme.terraTint.opacity(0.45) : Theme.creamBox,
                    in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("move-confirm-panel")
    }

    private var dayLabel: String {
        isToday ? "today" : day.formatted(.dateTime.weekday(.wide))
    }
}

/// "Move", with a small warning sign in front when it would break a rule.
private struct MoveLabelStyle: LabelStyle {
    var showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if showIcon { configuration.icon.font(.system(size: 13, weight: .semibold)) }
            configuration.title
        }
    }
}

/// A dose time being changed from Meds today, before she confirms.
private struct DoseMove: Equatable {
    struct Check: Equatable {
        var minutes: Int
        var reasons: [String]
        var alongside: [String]
    }

    var entryID: String
    var id: UUID
    var owner: MedOwner
    var name: String
    var original: Int
    var minutes: Int
    var wheel = false
    var check: Check?
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
