import Foundation

/// A proposed change to one day (or one routine), shown inline under the row it came from.
/// Nothing is saved until she picks "Just today" or "Today and every …"; a rule is never broken silently.
struct ScheduleChange: Identifiable, Equatable {
    enum Kind: Equatable {
        /// She moved a medication.
        case dose
        /// She moved a meal.
        case meal
        /// She logged a dose at a time that moves what comes after.
        case logged
        /// She changed a routine on the Routines screen.
        case routine
        /// She tapped a warning icon: rules already broken today.
        case review
        /// She changed, added or removed a rule on a medication card.
        case rule
        /// "Shift my day": everything not taken yet moves by the same amount.
        case shift
    }

    enum Placement: Equatable {
        /// Under a medication or meal row on Today.
        case row(UUID)
        /// Under the Right now card.
        case top
        /// Inside a routine on the Routines screen.
        case routine(UUID)
        /// Under a medication card on Meds & routines.
        case medication(UUID)
        /// Inside the Shift my day card.
        case shift
    }

    enum Scope { case today, forward }

    struct Problem: Identifiable, Equatable {
        var violation: RuleViolation
        /// "Iron needs at least 4 h after Thyroid. The earliest Iron can go is 11:15 PM, after bedtime."
        var reason: String
        var fixes: [ScheduleFix]
        var id: UUID { violation.id }
    }

    let id = UUID()
    var kind: Kind
    var placement: Placement
    var owner: MedOwner
    var date: Date
    var templateID: UUID?
    var routineName: String
    /// The medication or meal she changed.
    var subjectID: UUID?
    var subjectName: String
    var wake: Int
    var bed: Int
    var meals: [ScheduleMeal]
    var mealsChanged = false
    var wakeBedChanged = false
    /// Engine minutes for every dose that counts (taken doses at the time they were taken).
    var times: [UUID: Int]
    var original: [UUID: Int]
    /// Logged doses: never moved.
    var fixed: Set<UUID>
    var pinned: Set<UUID>
    var skips: Set<UUID> = []
    var range: ClosedRange<Int>
    var problems: [Problem] = []
    /// The closest time that keeps every rule for the medication she moved.
    var suggestion: Int?
    var kept = false
    var summary = ""
    /// Routine edits: the edited routine.
    var draft: ScheduleTemplate?
    /// Routine edits: "Just today" only makes sense when today follows this routine.
    var canApplyToday = true
    /// Doses on the day before (and for routines, the day after), for gap rules across midnight.
    var adjacent: [UUID: [Int]] = [:]
    /// A late evening dose moves tomorrow's doses: the change is for tomorrow only.
    var isNextDay = false
    /// Rule edits: this person's whole rule set as it would be. Saved only on "Going forward".
    var draftRules: [ScheduleRule]?
    /// Rule edits: every routine of this person re-placed under `draftRules`.
    var generated: [ScheduleTemplate] = []
    /// Rule edits: "Matches my doctor or pharmacist" is on.
    var confirmed = false
    /// Shift my day: minutes everything not taken yet moves (negative = earlier).
    var shift = 0
    /// Shift my day: she tapped Done, so the Just today / Every day choice shows.
    var asked = false
    /// A late dose also moved tomorrow's dose: one more line in this panel instead of a second popup.
    var followOn: AutoMoveNotice?

    /// Rules are being added or changed: she confirms they match her doctor or pharmacist first.
    var needsConfirmation: Bool { kind == .rule && !confirmed }

    var routine: EngineRoutine {
        EngineRoutine(wake: wake, bed: bed,
                      meals: meals.map { EngineMeal(name: $0.name, start: $0.time.minutesFromMidnight, duration: $0.durationMinutes) },
                      adjacent: adjacent)
    }

    /// Rules are broken and she hasn't chosen "Keep anyway".
    var needsDecision: Bool { !problems.isEmpty && !kept }

    /// The new time of the thing she changed, for the panel's first line.
    var subjectTime: Int? {
        guard let subjectID else { return nil }
        if let t = times[subjectID] { return t }
        return meals.first { $0.id == subjectID }?.time.minutesFromMidnight
    }
}

/// While a row is being dragged: where other doses would go and which rules would break.
struct DragPreview: Equatable {
    var subjectID: UUID
    var minutes: Int
    /// Doses that would move, with their new minute.
    var moved: [UUID: Int]
    /// Medication id → "Iron would be 3 h after Thyroid; needs 4 h".
    var broken: [UUID: String]
}

/// What a day looks like to the engine.
struct DayState {
    var template: ScheduleTemplate
    var wake: Int
    var bed: Int
    var meals: [ScheduleMeal]
    var times: [UUID: Int]
    var fixed: Set<UUID>
    var pinned: Set<UUID>
    var meds: [EngineMed]
    var range: ClosedRange<Int>
    /// The day before's doses on this day's axis (negative minutes), taken ones at the time taken.
    var adjacent: [UUID: [Int]] = [:]

    var routine: EngineRoutine {
        EngineRoutine(wake: wake, bed: bed,
                      meals: meals.map { EngineMeal(name: $0.name, start: $0.time.minutesFromMidnight, duration: $0.durationMinutes) },
                      adjacent: adjacent)
    }
}

enum DayEdit {
    case dose(UUID, Int)
    case meal(UUID, Int)
    case logged(UUID)
    case review
}

extension AppStore {
    // MARK: - Day state

    private func minutes(_ date: Date) -> Int {
        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// One person's day for the engine. Skipped doses are left out; taken ones are fixed at the time taken.
    /// Today, nothing new is placed before now.
    func dayState(_ owner: MedOwner, on day: Date) -> DayState? {
        guard let r = dayRoutine(owner, on: day) else { return nil }
        let cal = PregnancyMath.calendar
        let list = instances(on: day).filter { $0.medication.owner == owner && $0.medication.managed }
        var times: [UUID: Int] = [:]
        var fixed = Set<UUID>()
        var pinned = Set<UUID>()
        var meds: [EngineMed] = []
        for item in list where !item.isSkipped {
            let id = item.medication.id
            let t = minutes(item.anchor)
            times[id] = t
            if item.isTaken {
                fixed.insert(id)
            } else {
                let isPinned = r.template.dose(for: id)?.pinned == true
                if isPinned { pinned.insert(id) }
                meds.append(EngineMed(id: id, name: item.medication.shortName, pinned: isPinned ? t : nil))
            }
        }
        let wake = r.wake.minutesFromMidnight
        let bed = r.bed.minutesFromMidnight
        var lower = wake
        if cal.isDateInToday(day) { lower = max(wake, ScheduleEngine.roundUp(minutes(.now))) }
        return DayState(template: r.template, wake: wake, bed: bed, meals: r.meals, times: times, fixed: fixed,
                        pinned: pinned, meds: meds, range: lower...max(bed, lower),
                        adjacent: neighbourDoses(owner, around: day))
    }

    /// Yesterday's real doses and tomorrow's planned ones on `day`'s minute axis, so overnight gap rules
    /// ("10–12 h apart") are checked across midnight the way the routine was planned.
    func neighbourDoses(_ owner: MedOwner, around day: Date) -> [UUID: [Int]] {
        var result = previousDayDoses(owner, before: day)
        let cal = PregnancyMath.calendar
        let start = cal.startOfDay(for: day)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: start) else { return result }
        for item in instances(on: tomorrow) where item.medication.owner == owner && item.medication.managed && !item.isSkipped {
            result[item.medication.id, default: []].append(Int(item.anchor.timeIntervalSince(start) / 60))
        }
        return result
    }

    /// The day before's doses on `day`'s minute axis: negative minutes, taken doses at the time taken
    /// (one taken just after midnight lands on 0 or later). Skipped doses don't count.
    func previousDayDoses(_ owner: MedOwner, before day: Date) -> [UUID: [Int]] {
        let cal = PregnancyMath.calendar
        let start = cal.startOfDay(for: day)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: start) else { return [:] }
        var result: [UUID: [Int]] = [:]
        for item in instances(on: yesterday) where item.medication.owner == owner && item.medication.managed && !item.isSkipped {
            // To the app's 5-minute step, like every planned time (11:46 PM counts as 11:45 PM).
            let m = Int((item.anchor.timeIntervalSince(start) / 60).rounded())
            result[item.medication.id, default: []].append(ScheduleEngine.roundNearest(m))
        }
        return result
    }

    /// Rules whose medications are on the day; gap rules also when the other side is on the day before.
    func usableRules(_ owner: MedOwner, times: [UUID: Int], adjacent: [UUID: [Int]] = [:],
                             using draft: [ScheduleRule]? = nil) -> [ScheduleRule] {
        let routine = EngineRoutine(wake: 0, bed: 0, meals: [], adjacent: adjacent)
        let ids = Set(times.keys)
        return (draft ?? rules(for: owner)).filter { ScheduleEngine.applies($0, on: ids, routine: routine) }
            + ScheduleEngine.dayBounds(for: times.keys)
    }

    /// Rules that can still matter: they involve a dose not logged yet (or a meal she just moved).
    func openRules(_ owner: MedOwner, times: [UUID: Int], adjacent: [UUID: [Int]] = [:], fixed: Set<UUID>,
                           mealsChanged: Bool, using draft: [ScheduleRule]? = nil) -> [ScheduleRule] {
        usableRules(owner, times: times, adjacent: adjacent, using: draft).filter { rule in
            if times[rule.subjectID] != nil, !fixed.contains(rule.subjectID) { return true }
            if rule.target == .medication, let other = rule.targetMedicationID, times[other] != nil, !fixed.contains(other) { return true }
            return mealsChanged && (rule.target == .food || rule.target == .meal)
        }
    }

    /// Rules broken right now on a day, by doses not logged yet. Rows show a warning icon for these.
    func dayViolations(_ owner: MedOwner, on day: Date) -> [RuleViolation] {
        guard let s = dayState(owner, on: day) else { return [] }
        let open = openRules(owner, times: s.times, adjacent: s.adjacent, fixed: s.fixed, mealsChanged: false)
        return ScheduleEngine.violations(times: s.times, routine: s.routine, rules: open, names: medicationNames)
    }

    // MARK: - Drag preview

    /// Live result of moving a medication or meal to `minutes`, without saving anything.
    func previewDayChange(owner: MedOwner, day: Date, edit: DayEdit) -> DragPreview? {
        guard var s = dayState(owner, on: day) else { return nil }
        let before = s.times
        var locked = s.fixed
        let subject: UUID
        let target: Int
        var mealsChanged = false
        switch edit {
        case .dose(let id, let t):
            s.times[id] = t
            locked.insert(id)
            subject = id
            target = t
        case .meal(let id, let t):
            guard let i = s.meals.firstIndex(where: { $0.id == id }) else { return nil }
            s.meals[i].time = DoseTime(minutes: t)
            mealsChanged = true
            subject = id
            target = t
        case .logged, .review:
            return nil
        }
        let routine = s.routine
        let rules = usableRules(owner, times: s.times, adjacent: s.adjacent)
        let settled = ScheduleEngine.settle(times: s.times, locked: locked, meds: s.meds, routine: routine, rules: rules, range: s.range)
        var moved: [UUID: Int] = [:]
        for (id, t) in settled where id != subject && before[id] != t { moved[id] = t }
        let open = openRules(owner, times: settled, adjacent: s.adjacent, fixed: s.fixed, mealsChanged: mealsChanged)
        var broken: [UUID: String] = [:]
        for v in ScheduleEngine.violations(times: settled, routine: routine, rules: open, names: medicationNames) where broken[v.rule.subjectID] == nil {
            broken[v.rule.subjectID] = ScheduleEngine.shortReason(v)
        }
        return DragPreview(subjectID: subject, minutes: target, moved: moved, broken: broken)
    }

    /// Meds today: one dose moves to `minutes` on `day` only; the routine stays the same. Doses that rules tie to it
    /// settle around it the way a drag would; a broken rule is kept (she saw the reason and chose Move).
    /// Saves the day override (synced to the partner), rebuilds the plan, and refreshes reminders, widgets and the Live Activity.
    func moveDose(owner: MedOwner, day: Date, medicationID: UUID, to minutes: Int) {
        guard proposeDayChange(owner: owner, day: day, edit: .dose(medicationID, minutes), placement: .row(medicationID)) != nil
        else { return }
        scheduleChange?.kept = true
        applyChange(.today)
    }

    // MARK: - Proposals

    /// Works out a change to one day and shows it inline. Returns nil when there is nothing to ask
    /// (a late log that moves nothing, or a review with nothing broken).
    @discardableResult
    func proposeDayChange(owner: MedOwner, day: Date, edit: DayEdit, placement: ScheduleChange.Placement,
                          nextDay: Bool = false) -> ScheduleChange? {
        guard var s = dayState(owner, on: day) else { return nil }
        let names = medicationNames
        let original = s.times
        var locked = s.fixed
        var subjectID: UUID?
        var subjectName = ""
        var mealsChanged = false
        let kind: ScheduleChange.Kind
        switch edit {
        case .dose(let id, let t):
            s.times[id] = t
            locked.insert(id)
            subjectID = id
            subjectName = names[id] ?? "Medication"
            kind = .dose
        case .meal(let id, let t):
            guard let i = s.meals.firstIndex(where: { $0.id == id }) else { return nil }
            s.meals[i].time = DoseTime(minutes: t)
            s.meals.sort { $0.time < $1.time }
            mealsChanged = true
            subjectID = id
            subjectName = s.meals.first { $0.id == id }?.name ?? "Meal"
            kind = .meal
        case .logged(let id):
            subjectID = id
            subjectName = names[id] ?? "Medication"
            kind = .logged
        case .review:
            kind = .review
        }
        if kind != .review {
            s.times = ScheduleEngine.settle(times: s.times, locked: locked, meds: s.meds, routine: s.routine,
                                            rules: usableRules(owner, times: s.times, adjacent: s.adjacent), range: s.range)
        }
        var change = ScheduleChange(
            kind: kind, placement: placement, owner: owner, date: PregnancyMath.calendar.startOfDay(for: day),
            templateID: s.template.id, routineName: s.template.displayName, subjectID: subjectID, subjectName: subjectName,
            wake: s.wake, bed: s.bed, meals: s.meals, mealsChanged: mealsChanged, times: s.times, original: original,
            fixed: s.fixed, pinned: s.pinned, range: s.range, adjacent: s.adjacent, isNextDay: nextDay
        )
        refreshProblems(&change)
        switch kind {
        case .logged:
            let moves = change.times.contains { $0.key != subjectID && original[$0.key] != $0.value }
            let mine = change.problems.contains { subjectID.map($0.violation.rule.involves) ?? false }
            guard moves || mine else { return nil }
            // Tomorrow: only worth asking when a dose actually moves.
            if nextDay, !moves { return nil }
        case .review:
            guard !change.problems.isEmpty else { return nil }
        default:
            break
        }
        scheduleChange = change
        return change
    }

    /// An edit on the Routines screen: re-places the routine's doses and shows the result inside it.
    func proposeRoutineChange(original: ScheduleTemplate, edited: ScheduleTemplate, movedDose: UUID? = nil) {
        let adjacent = ScheduleCycle.adjacent(for: edited, in: templates(for: original.owner))
        let routine = EngineRoutine(edited, adjacent: adjacent)
        let meds = engineMeds(for: edited)
        var times = Dictionary(edited.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        for med in meds where times[med.id] == nil { times[med.id] = routine.wake }
        let before = Dictionary(original.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        let range = routine.wake...max(routine.bed, routine.wake)
        let rules = usableRules(original.owner, times: times, adjacent: adjacent)
        let settled = ScheduleEngine.settle(times: times, locked: movedDose.map { [$0] } ?? [], meds: meds,
                                            routine: routine, rules: rules, range: range)
        let today = PregnancyMath.calendar.startOfDay(for: now)
        var change = ScheduleChange(
            kind: .routine, placement: .routine(original.id), owner: original.owner, date: today,
            templateID: original.id, routineName: original.displayName, subjectID: movedDose,
            subjectName: movedDose.flatMap { medicationNames[$0] } ?? "",
            wake: edited.wake.minutesFromMidnight, bed: edited.bed.minutesFromMidnight, meals: edited.meals.sorted { $0.time < $1.time },
            mealsChanged: true, wakeBedChanged: true, times: settled, original: before, fixed: [],
            pinned: Set(edited.doses.filter(\.pinned).map(\.medicationID)), range: range,
            draft: edited, canApplyToday: activeTemplate(for: original.owner, on: today)?.id == original.id,
            adjacent: adjacent
        )
        refreshProblems(&change)
        scheduleChange = change
    }

    /// A rule changed, added or removed on a medication card: every routine is re-placed under the new rules and
    /// the result for `template` shows under the card. Nothing is saved until "Going forward" (or "Just today").
    /// Rules back to exactly what's saved: the panel closes.
    func proposeRuleChange(owner: MedOwner, template: ScheduleTemplate, rules newRules: [ScheduleRule],
                           medicationID: UUID, title: String) {
        if RuleSignature.same(newRules, rules(for: owner)) {
            scheduleChange = nil
            return
        }
        let generated = generateCycle(owner, rules: newRules)
        guard let placed = generated.templates.first(where: { $0.id == template.id }) else { return }
        let adjacent = ScheduleCycle.adjacent(for: placed, in: generated.templates)
        let times = Dictionary(placed.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        let before = Dictionary(template.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        let today = PregnancyMath.calendar.startOfDay(for: now)
        let wake = template.wake.minutesFromMidnight
        var change = ScheduleChange(
            kind: .rule, placement: .medication(medicationID), owner: owner, date: today,
            templateID: template.id, routineName: template.displayName, subjectID: medicationID, subjectName: title,
            wake: wake, bed: template.bed.minutesFromMidnight, meals: template.meals.sorted { $0.time < $1.time },
            mealsChanged: true, times: times, original: before, fixed: [],
            pinned: Set(template.doses.filter(\.pinned).map(\.medicationID)), range: wake...max(template.bed.minutesFromMidnight, wake),
            draft: template, canApplyToday: activeTemplate(for: owner, on: today)?.id == template.id, adjacent: adjacent
        )
        change.draftRules = newRules
        change.generated = generated.templates
        refreshProblems(&change)
        scheduleChange = change
    }

    /// Recomputes what's broken, the one-tap fixes and the summary line.
    func refreshProblems(_ change: inout ScheduleChange) {
        let names = medicationNames
        let routine = change.routine
        let open = openRules(change.owner, times: change.times, adjacent: change.adjacent, fixed: change.fixed,
                             mealsChanged: change.mealsChanged, using: change.draftRules)
        let usable = usableRules(change.owner, times: change.times, adjacent: change.adjacent, using: change.draftRules)
        let violations = ScheduleEngine.violations(times: change.times, routine: routine, rules: open, names: names)
        change.suggestion = nil
        if let id = change.subjectID, change.kind == .dose || change.kind == .routine || change.kind == .rule, let t = change.times[id],
           violations.contains(where: { $0.rule.involves(id) }),
           let best = ScheduleEngine.closestValid(for: id, near: t, times: change.times, routine: routine, rules: usable, range: change.range),
           best != t {
            change.suggestion = best
        }
        let suggestion = change.suggestion
        let subject = change.subjectID
        change.problems = violations.map { v in
            var fixes = ScheduleEngine.fixes(for: v, times: change.times, fixed: change.fixed, routine: routine, rules: usable,
                                             names: names, range: change.range, allowSkip: change.kind != .routine && change.kind != .rule,
                                             pinned: change.pinned)
                .filter { fix in
                    if case .move(let id, let t) = fix.kind, id == subject, t == suggestion { return false }
                    return true
                }
            // On a routine there's no skipping: when no dose can move, offer the smallest change to the day itself.
            if change.kind == .routine || change.kind == .rule, fixes.isEmpty, suggestion == nil, let draft = change.draft {
                fixes = ScheduleEngine.routineFixes(for: v, times: change.times, meds: engineMeds(for: draft), routine: routine,
                                                    rules: usable, names: names)
            }
            let reason = ScheduleEngine.blockedReason(for: v, times: change.times, fixed: change.fixed, routine: routine,
                                                      rules: usable, names: names, range: change.range)
            return ScheduleChange.Problem(violation: v, reason: reason, fixes: fixes)
        }
        change.summary = summaryLine(change)
    }

    private func summaryLine(_ change: ScheduleChange) -> String {
        let names = medicationNames
        var parts: [String] = []
        if change.kind == .shift {
            return change.shift == 0 ? "Times as planned"
                : "Everything \(ScheduleEngine.duration(abs(change.shift))) \(change.shift > 0 ? "later" : "earlier") · gaps kept"
        }
        let moved = change.times
            .filter { $0.key != change.subjectID && change.original[$0.key] != nil && change.original[$0.key] != $0.value }
            .sorted { $0.value < $1.value }
        for (id, t) in moved { parts.append("\(names[id] ?? "Medication") moves to \(ScheduleEngine.clock(t))") }
        for id in change.skips.sorted(by: { (names[$0] ?? "") < (names[$1] ?? "") }) {
            parts.append("\(names[id] ?? "Medication") skipped today")
        }
        // The meal the moved medication goes with or around stays put.
        if let id = change.subjectID, change.kind == .dose {
            let mealRule = rules(for: change.owner).first { $0.subjectID == id && $0.target == .meal }
            if let mealRule, let meal = change.routine.meal(named: mealRule.targetMeal) {
                parts.append("\(meal.name) stays \(ScheduleEngine.clock(meal.start))")
            }
        }
        if parts.isEmpty { parts.append(change.kind == .routine ? "Medication times stay the same" : "Nothing else moves") }
        let line = parts.joined(separator: " · ")
        return change.isNextDay ? "Tomorrow: \(line)" : line
    }

    // MARK: - Choices in the panel

    func applyFix(_ fix: ScheduleFix) {
        guard var change = scheduleChange else { return }
        switch fix.kind {
        case .move(let id, let t): change.times[id] = t
        case .skip(let id):
            change.times[id] = nil
            change.skips.insert(id)
        case .retime(let tweak):
            if let w = tweak.wake { change.wake = w; change.draft?.wake = DoseTime(minutes: w) }
            if let b = tweak.bed { change.bed = b; change.draft?.bed = DoseTime(minutes: b) }
            if let name = tweak.mealName, let start = tweak.mealStart {
                if let i = change.meals.firstIndex(where: { $0.name == name }) { change.meals[i].time = DoseTime(minutes: start) }
                if let i = change.draft?.meals.firstIndex(where: { $0.name == name }) { change.draft?.meals[i].time = DoseTime(minutes: start) }
            }
            change.times = tweak.times
            change.range = change.wake...max(change.bed, change.wake)
        }
        change.kept = false
        refreshProblems(&change)
        Haptics.tap()
        // The fix put everything back where it was: nothing left to decide.
        let sameDay: Bool = {
            switch change.kind {
            case .dose, .meal: return !change.mealsChanged && !change.wakeBedChanged
            case .routine:
                guard let saved = templates.first(where: { $0.id == change.templateID }), let draft = change.draft else { return false }
                return saved.wake == draft.wake && saved.bed == draft.bed && saved.meals.map(\.time) == draft.meals.map(\.time)
                    && saved.name == draft.name && saved.days == draft.days
            default: return false
            }
        }()
        if sameDay, change.problems.isEmpty, change.skips.isEmpty, change.times == change.original {
            scheduleChange = nil
            return
        }
        scheduleChange = change
    }

    func useSuggestion() {
        guard let change = scheduleChange, let id = change.subjectID, let t = change.suggestion else { return }
        applyFix(ScheduleFix(title: "", kind: .move(id, t)))
    }

    func keepAnyway() {
        scheduleChange?.kept = true
        Haptics.warning()
    }

    func discardChange() {
        scheduleChange = nil
        Haptics.select()
    }

    /// "Just today" or "Today and every …" / "Going forward".
    func applyChange(_ scope: ScheduleChange.Scope) {
        guard let change = scheduleChange, !change.needsConfirmation else { return }
        scheduleChange = nil
        if change.kind == .rule, let draft = change.draft {
            applyRuleChange(change, draft: draft, scope: scope)
            Haptics.success()
            return
        }
        if change.kind == .routine, let draft = change.draft {
            applyRoutineChange(change, draft: draft, scope: scope)
            Haptics.success()
            return
        }
        if change.kind == .shift {
            applyShift(change, scope: scope)
            Haptics.success()
            return
        }
        writeDayOverride(change, meals: change.mealsChanged ? change.meals : nil, wake: nil, bed: nil)
        if scope == .forward, var t = templates.first(where: { $0.id == change.templateID }) {
            for (id, m) in change.times where !change.fixed.contains(id) || (change.kind == .logged && id == change.subjectID) {
                guard let i = t.doses.firstIndex(where: { $0.medicationID == id }) else { continue }
                t.doses[i].time = DoseTime(minutes: ScheduleEngine.roundNearest(m))
            }
            if change.mealsChanged { t.meals = change.meals }
            saveTemplate(t, regenerate: false)
        } else {
            rebuildPlan()
            saveAndReschedule()
        }
        applySkips(change)
        Haptics.success()
    }

    private func applyRoutineChange(_ change: ScheduleChange, draft: ScheduleTemplate, scope: ScheduleChange.Scope) {
        var t = draft
        switch scope {
        case .forward:
            for (id, m) in change.times {
                if let i = t.doses.firstIndex(where: { $0.medicationID == id }) {
                    t.doses[i].time = DoseTime(minutes: m)
                } else {
                    t.doses.append(TemplateDose(medicationID: id, time: DoseTime(minutes: m)))
                }
            }
            saveTemplate(t, regenerate: false)
        case .today:
            guard change.canApplyToday else { return }
            writeDayOverride(change, meals: change.meals, wake: DoseTime(minutes: change.wake), bed: DoseTime(minutes: change.bed))
            rebuildPlan()
            saveAndReschedule()
        }
    }

    /// Rule edits. Going forward: the rules are saved (confirmed) and every routine takes its new times.
    /// Just today: today takes the new times; the saved rules stay as they were.
    private func applyRuleChange(_ change: ScheduleChange, draft: ScheduleTemplate, scope: ScheduleChange.Scope) {
        guard let newRules = change.draftRules else { return }
        switch scope {
        case .forward:
            commitRules(change.owner, newRules)
            var list = change.generated
            var t = draft
            for (id, m) in change.times {
                if let i = t.doses.firstIndex(where: { $0.medicationID == id }) {
                    t.doses[i].time = DoseTime(minutes: m)
                } else {
                    t.doses.append(TemplateDose(medicationID: id, time: DoseTime(minutes: m)))
                }
            }
            if let i = list.firstIndex(where: { $0.id == t.id }) { list[i] = t } else { list.append(t) }
            storeGenerated(list)
            rebuildPlan()
            saveAndReschedule()
        case .today:
            guard change.canApplyToday else { return }
            writeDayOverride(change, meals: change.meals, wake: DoseTime(minutes: change.wake), bed: DoseTime(minutes: change.bed))
            rebuildPlan()
            saveAndReschedule()
        }
    }

    /// One day's times for every managed medication of this person. Logged doses keep their planned time
    /// so their logs stay attached; a medication missing here would vanish from the day.
    func writeDayOverride(_ change: ScheduleChange, meals: [ScheduleMeal]?, wake: DoseTime?, bed: DoseTime?) {
        let day = change.date
        let list = instances(on: day).filter { $0.medication.owner == change.owner && $0.medication.managed }
        var times: [UUID: DoseTime] = [:]
        for item in list {
            let id = item.medication.id
            if item.isPending, let m = change.times[id] {
                times[id] = DoseTime(minutes: m)
            } else {
                times[id] = DoseTime(date: item.scheduledAt)
            }
        }
        // Medications without a dose yet that day (a routine edit placed them).
        for (id, m) in change.times where times[id] == nil && scheduledMedications(for: change.owner).contains(where: { $0.id == id }) {
            times[id] = DoseTime(minutes: m)
        }
        let existing = override(for: change.owner, on: day)
        // A dose she moved herself no longer follows a meal.
        let adjusted = existing?.adjusted?.filter { times[$0.key] != nil && times[$0.key] == existing?.times[$0.key] }
        overrides.removeAll { $0.owner == change.owner && PregnancyMath.calendar.isDate($0.date, inSameDayAs: day) }
        overrides.append(DayOverride(
            id: existing?.id ?? UUID(), owner: change.owner, takerID: isShared ? memberID(for: change.owner) : nil,
            date: day, times: times, templateID: change.templateID,
            meals: meals ?? existing?.meals, wake: wake ?? existing?.wake, bed: bed ?? existing?.bed,
            adjusted: (adjusted?.isEmpty ?? true) ? nil : adjusted
        ))
        enqueue(.plan, change.owner.rawValue)
    }

    private func applySkips(_ change: ScheduleChange) {
        for id in change.skips {
            if let instance = instances(on: change.date).first(where: { $0.medication.id == id && $0.isPending }) {
                skip(instance)
            }
        }
    }

    // MARK: - Late logging

    /// After a dose is logged: if the real time moves later doses or breaks a rule, ask inline.
    /// Tomorrow is always checked too (when the log was saved): a late evening dose moves tomorrow's dose by itself.
    /// When today's panel is showing, that move is one more line in it rather than a separate banner.
    func proposeAfterLogging(_ instance: DoseInstance, placement: ScheduleChange.Placement) {
        let med = instance.medication
        guard med.managed else { return }
        if PregnancyMath.calendar.isDateInToday(instance.scheduledAt) {
            proposeDayChange(owner: med.owner, day: instance.scheduledAt, edit: .logged(med.id), placement: placement)
        }
        if autoMoveLateDoses() { saveAndReschedule() }
        if var change = scheduleChange, let notice = autoMoveNotice, notice.owner == change.owner,
           Date.now.timeIntervalSince(notice.createdAt) < 10 {
            change.followOn = notice
            scheduleChange = change
            autoMoveNotice = nil
        }
    }

    // MARK: - Routines for a day

    /// Today (or another day) follows a different routine. Logged doses keep their times.
    func switchRoutine(_ owner: MedOwner, on day: Date, to template: ScheduleTemplate) {
        let cal = PregnancyMath.calendar
        let start = cal.startOfDay(for: day)
        let list = instances(on: day).filter { $0.medication.owner == owner && $0.medication.managed }
        let isDefault = self.template(for: owner, on: day)?.id == template.id
        var needsOverride = !isDefault
        var times: [UUID: DoseTime] = [:]
        for med in scheduledMedications(for: owner) {
            if let item = list.first(where: { $0.medication.id == med.id }), !item.isPending {
                let kept = DoseTime(date: item.scheduledAt)
                times[med.id] = kept
                if template.dose(for: med.id)?.time != kept { needsOverride = true }
            } else if let dose = template.dose(for: med.id) {
                times[med.id] = dose.time
            }
        }
        overrides.removeAll { $0.owner == owner && cal.isDate($0.date, inSameDayAs: day) }
        if needsOverride {
            overrides.append(DayOverride(owner: owner, takerID: isShared ? memberID(for: owner) : nil,
                                         date: start, times: times, templateID: template.id))
        }
        scheduleChange = nil
        enqueue(.plan, owner.rawValue)
        rebuildPlan()
        saveAndReschedule()
        Haptics.success()
    }

    /// Gives a weekday to `template`, taking it from whichever routine had it.
    func moveDay(_ day: Int, to template: ScheduleTemplate) {
        for other in templates(for: template.owner) where other.id != template.id && other.days.contains(day) {
            var o = other
            o.days.remove(day)
            saveTemplate(o, regenerate: false)
        }
        var t = templates.first { $0.id == template.id } ?? template
        t.days.insert(day)
        saveTemplate(t, regenerate: false)
    }

    // MARK: - Fixes on a routine (the medication box)

    /// One-tap fixes for a rule a routine breaks.
    func templateFixes(_ template: ScheduleTemplate, for violation: RuleViolation) -> [ScheduleFix] {
        let routine = engineRoutine(template)
        let times = Dictionary(template.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        let rules = usableRules(template.owner, times: times, adjacent: routine.adjacent)
        let fixes = ScheduleEngine.fixes(for: violation, times: times, fixed: [], routine: routine,
                                         rules: rules, names: medicationNames,
                                         range: routine.wake...max(routine.bed, routine.wake), allowSkip: false,
                                         pinned: Set(template.doses.filter(\.pinned).map(\.medicationID)))
        if !fixes.isEmpty { return fixes }
        return ScheduleEngine.routineFixes(for: violation, times: times, meds: engineMeds(for: template), routine: routine,
                                           rules: rules, names: medicationNames)
    }

    func templateBlockedReason(_ template: ScheduleTemplate, for violation: RuleViolation) -> String {
        let routine = engineRoutine(template)
        let times = Dictionary(template.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        return ScheduleEngine.blockedReason(for: violation, times: times, fixed: [], routine: routine,
                                            rules: usableRules(template.owner, times: times, adjacent: routine.adjacent), names: medicationNames,
                                            range: routine.wake...max(routine.bed, routine.wake))
    }

    /// Applies a fix to a routine and returns what's still broken.
    @discardableResult
    func applyTemplateFix(_ templateID: UUID, fix: ScheduleFix) -> [RuleViolation] {
        guard var t = templates.first(where: { $0.id == templateID }) else { return [] }
        switch fix.kind {
        case .move(let id, let m):
            guard let i = t.doses.firstIndex(where: { $0.medicationID == id }) else { return [] }
            t.doses[i].time = DoseTime(minutes: m)
        case .retime(let tweak):
            if let w = tweak.wake { t.wake = DoseTime(minutes: w) }
            if let b = tweak.bed { t.bed = DoseTime(minutes: b) }
            if let name = tweak.mealName, let start = tweak.mealStart, let i = t.meals.firstIndex(where: { $0.name == name }) {
                t.meals[i].time = DoseTime(minutes: start)
            }
            for (id, m) in tweak.times {
                if let i = t.doses.firstIndex(where: { $0.medicationID == id }) { t.doses[i].time = DoseTime(minutes: m) }
            }
        case .skip:
            return []
        }
        Haptics.success()
        return saveTemplate(t, regenerate: false)
    }
}
