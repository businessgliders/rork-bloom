import Foundation

/// Another medication that moves along with the one she moves.
struct MovedDose: Equatable, Hashable {
    var id: UUID
    var name: String
    var minutes: Int
}

/// One ready-made time in the Move sheet. Every rule is kept at this time, including by what moves along.
struct MoveOption: Identifiable, Equatable {
    var minutes: Int
    /// The whole day's times with this option.
    var times: [UUID: Int]
    var alongside: [MovedDose]
    var id: Int { minutes }
}

/// What the Move sheet shows for one medication today.
struct MovePlan: Equatable {
    var medicationID: UUID
    var name: String
    var current: Int
    var options: [MoveOption]
    /// "At least 4 h after Thyroid · No food 2 h before, 1 h after"
    var limits: String
    /// Medications tied to this one by a rule; they move with it.
    var dependents: [String]
    var routineName: String
}

/// Where a dragged medication can be dropped (board 3).
struct DropBands: Equatable {
    var medicationID: UUID
    var current: Int
    /// The green band. nil = nothing else fits on this day.
    var safe: ClosedRange<Int>?
    var options: [Int: MoveOption]
    var beforeReason: String?
    var afterReason: String?
}

extension AppStore {
    // MARK: - Linked medications

    private func medicationRules(_ owner: MedOwner) -> [ScheduleRule] {
        rules(for: owner).filter { $0.target == .medication && $0.targetMedicationID != nil && $0.targetMedicationID != $0.subjectID }
    }

    /// Medications whose rules point at `id` ("Iron at least 4 h after Thyroid"), and theirs in turn.
    /// They move when `id` moves, so the gaps stay.
    func dependents(of id: UUID, owner: MedOwner) -> [UUID] {
        let list = medicationRules(owner)
        var out: [UUID] = []
        var queue = [id]
        var seen: Set<UUID> = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for rule in list where rule.targetMedicationID == current && !seen.contains(rule.subjectID) {
                seen.insert(rule.subjectID)
                out.append(rule.subjectID)
                queue.append(rule.subjectID)
            }
        }
        return out
    }

    /// Medications tied together by rules, numbered by group for the coloured line. Unlinked ones are left out.
    func linkGroups(_ owner: MedOwner) -> [UUID: Int] {
        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        for rule in medicationRules(owner) {
            guard let other = rule.targetMedicationID else { continue }
            if parent[rule.subjectID] == nil { parent[rule.subjectID] = rule.subjectID }
            if parent[other] == nil { parent[other] = other }
            let a = find(rule.subjectID), b = find(other)
            if a != b { parent[a] = b }
        }
        var groupOf: [UUID: Int] = [:]
        var result: [UUID: Int] = [:]
        for med in currentMedications(for: owner) where parent[med.id] != nil {
            let root = find(med.id)
            if groupOf[root] == nil { groupOf[root] = groupOf.count }
            result[med.id] = groupOf[root]
        }
        return result
    }

    /// "Linked to Thyroid": the medication it follows, else the ones that follow it.
    func linkText(for id: UUID, owner: MedOwner) -> String? {
        let names = medicationNames
        let list = medicationRules(owner)
        var linked: [String] = []
        for rule in list where rule.subjectID == id {
            if let other = rule.targetMedicationID, let name = names[other], !linked.contains(name) { linked.append(name) }
        }
        if linked.isEmpty {
            for rule in list where rule.targetMedicationID == id {
                if let name = names[rule.subjectID], !linked.contains(name) { linked.append(name) }
            }
        }
        guard !linked.isEmpty else { return nil }
        return "Linked to \(linked.formatted(.list(type: .and)))"
    }

    // MARK: - Rules in plain words

    /// One line for a medication's own rules: "At least 4 h after Thyroid · No food 2 h before, 1 h after".
    func ruleLine(for id: UUID, owner: MedOwner) -> String {
        let names = medicationNames
        let mine = rules(for: owner).filter { $0.subjectID == id }
        var parts: [String] = []
        var noFoodBefore: Int?
        var noFoodAfter: Int?
        for rule in mine {
            if rule.isNoFood {
                let m = rule.minMinutes ?? 0
                switch rule.relation {
                case .before: noFoodAfter = max(noFoodAfter ?? 0, m)
                case .after: noFoodBefore = max(noFoodBefore ?? 0, m)
                default:
                    noFoodBefore = max(noFoodBefore ?? 0, m)
                    noFoodAfter = max(noFoodAfter ?? 0, m)
                }
            } else {
                let title = RuleValues.title(rule, names: names)
                if !parts.contains(title) { parts.append(title) }
            }
        }
        let d = ScheduleEngine.duration
        switch (noFoodBefore, noFoodAfter) {
        case let (b?, a?): parts.append(b == a ? "No food \(d(b)) before or after" : "No food \(d(b)) before, \(d(a)) after")
        case let (b?, nil): parts.append("No food \(d(b)) before")
        case let (nil, a?): parts.append("No food \(d(a)) after")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Move sheet

    /// Up to five times today that keep every rule for this medication and everything that moves with it.
    func movePlan(owner: MedOwner, day: Date, medicationID id: UUID) -> MovePlan? {
        guard let s = dayState(owner, on: day), let current = s.times[id], !s.fixed.contains(id) else { return nil }
        let names = medicationNames
        // Doses already due earlier today stay where they are; only what's still to come moves along.
        let past = Set(s.times.filter { !s.fixed.contains($0.key) && $0.key != id && $0.value < s.range.lowerBound }.keys)
        let deps = dependents(of: id, owner: owner).filter { s.times[$0] != nil && !s.fixed.contains($0) && !past.contains($0) }
        let routine = s.routine
        var valid: [MoveOption] = []
        // Round clock times (quarter hours) read better than "21:50".
        let start = (s.range.lowerBound + 14) / 15 * 15
        if start <= s.range.upperBound {
            for t in stride(from: start, through: s.range.upperBound, by: 15) where t != current {
                guard let option = option(owner: owner, state: s, id: id, current: current, to: t, deps: deps, past: past,
                                          routine: routine, names: names) else { continue }
                valid.append(option)
            }
        }
        // The nearest ones first, at least 30 min apart, then in time order.
        var picked: [MoveOption] = []
        for option in valid.sorted(by: { abs($0.minutes - current) < abs($1.minutes - current) }) {
            if picked.allSatisfy({ abs($0.minutes - option.minutes) >= 30 }) { picked.append(option) }
            if picked.count == 5 { break }
        }
        return MovePlan(
            medicationID: id, name: names[id] ?? "Medication", current: current,
            options: picked.sorted { $0.minutes < $1.minutes },
            limits: ruleLine(for: id, owner: owner),
            dependents: deps.compactMap { names[$0] },
            routineName: s.template.displayName
        )
    }

    private func option(owner: MedOwner, state s: DayState, id: UUID, current: Int, to t: Int, deps: [UUID], past: Set<UUID>,
                        routine: EngineRoutine, names: [UUID: String]) -> MoveOption? {
        var times = s.times
        let delta = t - current
        times[id] = t
        for d in deps { if let m = times[d] { times[d] = m + delta } }
        let rules = usableRules(owner, times: times, adjacent: s.adjacent)
        let settled = ScheduleEngine.settle(times: times, locked: s.fixed.union(past).union([id]), meds: s.meds, routine: routine,
                                            rules: rules, range: s.range)
        guard settled[id] == t else { return nil }
        let moved = settled.filter { $0.key != id && s.times[$0.key] != $0.value }
        guard moved.values.allSatisfy({ s.range.contains($0) }) else { return nil }
        // Only rules about what moves count: something already off elsewhere today doesn't hide every option.
        let touched = Set(moved.keys).union([id])
        let open = openRules(owner, times: settled, adjacent: s.adjacent, fixed: s.fixed, mealsChanged: false)
        let broken = ScheduleEngine.violations(times: settled, routine: routine, rules: open, names: names)
            .filter { v in touched.contains { v.rule.involves($0) } }
        guard broken.isEmpty else { return nil }
        let alongside = moved
            .map { MovedDose(id: $0.key, name: names[$0.key] ?? "Medication", minutes: $0.value) }
            .sorted { $0.minutes < $1.minutes }
        return MoveOption(minutes: t, times: settled, alongside: alongside)
    }

    /// Saves one of the ready-made times: "Just today" or "Every day".
    func applyMove(owner: MedOwner, day: Date, option: MoveOption, medicationID id: UUID, scope: ScheduleChange.Scope) {
        guard let s = dayState(owner, on: day) else { return }
        let change = ScheduleChange(
            kind: .dose, placement: .row(id), owner: owner, date: PregnancyMath.calendar.startOfDay(for: day),
            templateID: s.template.id, routineName: s.template.displayName, subjectID: id,
            subjectName: medicationNames[id] ?? "Medication", wake: s.wake, bed: s.bed, meals: s.meals,
            times: option.times, original: s.times, fixed: s.fixed, pinned: s.pinned, range: s.range, adjacent: s.adjacent
        )
        scheduleChange = change
        applyChange(scope)
    }

    // MARK: - Drag bands (Meds & routines)

    /// Where a dragged medication can land on `day`, at 5-minute steps: the green band around its time
    /// and a one-line reason for each side.
    func dropBands(owner: MedOwner, day: Date, medicationID id: UUID) -> DropBands? {
        guard let s = dayState(owner, on: day), let current = s.times[id], !s.fixed.contains(id) else { return nil }
        let names = medicationNames
        let past = Set(s.times.filter { !s.fixed.contains($0.key) && $0.key != id && $0.value < s.range.lowerBound }.keys)
        let deps = dependents(of: id, owner: owner).filter { s.times[$0] != nil && !s.fixed.contains($0) && !past.contains($0) }
        let routine = s.routine
        let step = ScheduleEngine.step
        let first = (s.range.lowerBound + step - 1) / step * step
        var options: [Int: MoveOption] = [:]
        if first <= s.range.upperBound {
            for t in stride(from: first, through: s.range.upperBound, by: step) {
                if let o = option(owner: owner, state: s, id: id, current: current, to: t, deps: deps, past: past,
                                  routine: routine, names: names) {
                    options[t] = o
                }
            }
        }
        // The run of valid times around (or nearest to) where it is now.
        let snapped = ScheduleEngine.roundNearest(current)
        let seed = options.keys.min { abs($0 - snapped) < abs($1 - snapped) }
        var safe: ClosedRange<Int>?
        if let seed {
            var lo = seed, hi = seed
            while options[lo - step] != nil { lo -= step }
            while options[hi + step] != nil { hi += step }
            safe = lo...hi
        }
        func reason(at t: Int) -> String {
            if t < s.range.lowerBound {
                return PregnancyMath.calendar.isDateInToday(day) && t >= s.wake ? "Already past" : "Before you wake"
            }
            if t > s.range.upperBound { return "After bedtime" }
            var times = s.times
            times[id] = t
            for d in deps { if let m = times[d] { times[d] = m + (t - current) } }
            let open = openRules(owner, times: times, adjacent: s.adjacent, fixed: s.fixed, mealsChanged: false)
            let broken = ScheduleEngine.violations(times: times, routine: routine, rules: open, names: names)
                .filter { $0.rule.involves(id) || deps.contains(where: $0.rule.involves) }
            if let v = broken.first { return ScheduleEngine.shortReason(v) }
            return "Another rule can't be kept"
        }
        return DropBands(
            medicationID: id, current: current, safe: safe, options: options,
            beforeReason: safe.map { reason(at: $0.lowerBound - step) },
            afterReason: safe.map { reason(at: $0.upperBound + step) }
        )
    }

    // MARK: - Shift my day

    private func nowMinutes(on day: Date) -> Int {
        guard PregnancyMath.calendar.isDateInToday(day) else { return 0 }
        let c = PregnancyMath.calendar.dateComponents([.hour, .minute], from: .now)
        return ScheduleEngine.roundUp((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Doses still to come (not taken, not already due).
    private func shiftable(_ s: DayState, day: Date) -> [UUID] {
        let floor = nowMinutes(on: day)
        return s.times.filter { !s.fixed.contains($0.key) && $0.value >= floor }.map(\.key)
    }

    /// How far everything can move: from now (today) to just before midnight.
    func shiftBounds(_ owner: MedOwner, day: Date) -> ClosedRange<Int>? {
        guard let s = dayState(owner, on: day) else { return nil }
        let ids = shiftable(s, day: day)
        guard let first = ids.compactMap({ s.times[$0] }).min(), let last = ids.compactMap({ s.times[$0] }).max() else { return nil }
        let earlier = max(0, first - nowMinutes(on: day))
        let later = max(0, 1439 - last)
        return -earlier...later
    }

    /// Moves every dose and meal still to come (and bedtime) by `total` minutes; nothing is saved yet.
    func proposeShift(_ owner: MedOwner, day: Date, by total: Int) {
        guard total != 0 else {
            if scheduleChange?.kind == .shift { scheduleChange = nil }
            return
        }
        guard let s = dayState(owner, on: day) else { return }
        let floor = nowMinutes(on: day)
        var times = s.times
        for id in shiftable(s, day: day) { if let m = s.times[id] { times[id] = m + total } }
        var meals = s.meals
        for i in meals.indices where meals[i].time.minutesFromMidnight >= floor {
            meals[i].time = DoseTime(minutes: min(max(meals[i].time.minutesFromMidnight + total, 0), 1439))
        }
        meals.sort { $0.time < $1.time }
        let bed = s.bed > s.wake ? min(max(s.bed + total, s.wake), 1439) : s.bed
        let lower = s.range.lowerBound
        var change = ScheduleChange(
            kind: .shift, placement: .shift, owner: owner, date: PregnancyMath.calendar.startOfDay(for: day),
            templateID: s.template.id, routineName: s.template.displayName, subjectID: nil, subjectName: "",
            wake: s.wake, bed: bed, meals: meals, mealsChanged: true, wakeBedChanged: true, times: times, original: s.times,
            fixed: s.fixed, pinned: s.pinned, range: lower...max(bed, lower), adjacent: s.adjacent
        )
        change.shift = total
        refreshProblems(&change)
        scheduleChange = change
    }

    /// Just today: today's remaining doses, meals and bedtime move. Every day: the routine moves too (gaps kept).
    func applyShift(_ change: ScheduleChange, scope: ScheduleChange.Scope) {
        writeDayOverride(change, meals: change.meals, wake: nil, bed: DoseTime(minutes: change.bed))
        if scope == .forward, var t = templates.first(where: { $0.id == change.templateID }) {
            let delta = change.shift
            func moved(_ time: DoseTime) -> DoseTime {
                DoseTime(minutes: min(max(time.minutesFromMidnight + delta, 0), 1439))
            }
            for i in t.doses.indices { t.doses[i].time = moved(t.doses[i].time) }
            for i in t.meals.indices { t.meals[i].time = moved(t.meals[i].time) }
            // Bedtime after midnight (earlier on the clock than waking) stays put.
            if t.bed > t.wake { t.bed = moved(t.bed) }
            t.wake = moved(t.wake)
            saveTemplate(t, regenerate: false)
        } else {
            rebuildPlan()
            saveAndReschedule()
        }
    }
}
