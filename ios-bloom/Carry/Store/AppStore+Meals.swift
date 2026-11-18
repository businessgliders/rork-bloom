import Foundation

/// A meal she checked off on Meds today. `eatenAt` is when she finished eating.
struct MealLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var owner: MedOwner
    /// Start of the local day.
    var date: Date
    var kind: MealKind
    /// When the routine planned the meal to start.
    var plannedAt: Date?
    var eatenAt: Date
    var loggedBy: UUID?
    var updatedAt: Date = .now
}

/// A meal tapped "Eaten" on the Live Activity while food had to wait, shown as the guard on Meds today.
struct MealGuardRequest: Equatable {
    var id = UUID()
    var owner: MedOwner
    var kind: MealKind
}

nonisolated extension SyncOp {
    /// "mom|2026-11-17|lunch"
    static func mealKey(owner: MedOwner, day: Date, kind: MealKind) -> String {
        "\(owner.rawValue)|\(PlanDay.key(day))|\(kind.rawValue)"
    }

    static func parseMealKey(_ key: String) -> (MedOwner, Date, MealKind)? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 3, let owner = MedOwner(rawValue: parts[0]), let day = PlanDay.date(parts[1]),
              let kind = MealKind(rawValue: parts[2]) else { return nil }
        return (owner, day, kind)
    }
}

extension AppStore {
    // MARK: - Meal logs

    /// The routine meals that get a check: the first of each kind.
    func checkableMeals(_ owner: MedOwner, on day: Date) -> [MealKind: ScheduleMeal] {
        var result: [MealKind: ScheduleMeal] = [:]
        for meal in meals(for: owner, on: day) {
            let kind = MealKind.of(meal.name)
            if result[kind] == nil { result[kind] = meal }
        }
        return result
    }

    func mealLog(_ owner: MedOwner, on day: Date, kind: MealKind) -> MealLog? {
        mealLogs.first { $0.owner == owner && $0.kind == kind && PregnancyMath.calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Either phone can log a meal for the person whose routine it is.
    func logMeal(_ meal: ScheduleMeal, owner: MedOwner, day: Date, at time: Date) {
        let cal = PregnancyMath.calendar
        let start = cal.startOfDay(for: day)
        let kind = MealKind.of(meal.name)
        var log = mealLog(owner, on: day, kind: kind) ?? MealLog(owner: owner, date: start, kind: kind, eatenAt: time)
        log.plannedAt = meal.time.date(on: start)
        log.eatenAt = time
        log.loggedBy = myUserID
        log.updatedAt = .now
        mealLogs.removeAll { $0.owner == owner && $0.kind == kind && cal.isDate($0.date, inSameDayAs: day) }
        mealLogs.append(log)
        pruneMealLogs()
        enqueue(.meal, SyncOp.mealKey(owner: owner, day: start, kind: kind))
        replanMeals(owner, on: day)
    }

    /// "Eaten" on the Live Activity (app closed or open; either phone).
    /// Logs today's meal of that kind now and re-plans. During a running no-food window nothing is logged:
    /// a notice opens Meds today with "No food until … Log breakfast anyway?".
    func eatenFromLiveActivity(owner: MedOwner, kind: MealKind, at time: Date = .now) {
        guard PregnancyMath.calendar.isDateInToday(time),
              let meal = checkableMeals(owner, on: time)[kind],
              mealLog(owner, on: time, kind: kind) == nil else {
            LiveActivityController.sync(store: self)
            return
        }
        if let alert = activeNoFood(owner, at: time), time >= alert.firstTakenAt, time < alert.end {
            pendingMealGuard = MealGuardRequest(owner: owner, kind: kind)
            MedNotifications.postMealGuard(alert, mealName: meal.name, owner: owner, kind: kind)
            LiveActivityController.sync(store: self)
            return
        }
        logMeal(meal, owner: owner, day: time, at: time)
    }

    /// Meal taps the widget extension queued, if the system ever ran the intent there.
    func applyPendingMealTaps() {
        for tap in PendingMealTaps.take() {
            guard let owner = MedOwner(rawValue: tap.role), let kind = MealKind(rawValue: tap.meal) else { continue }
            eatenFromLiveActivity(owner: owner, kind: kind, at: tap.at)
        }
    }

    func undoMeal(_ meal: ScheduleMeal, owner: MedOwner, day: Date) {
        let cal = PregnancyMath.calendar
        let kind = MealKind.of(meal.name)
        mealLogs.removeAll { $0.owner == owner && $0.kind == kind && cal.isDate($0.date, inSameDayAs: day) }
        enqueue(.meal, SyncOp.mealKey(owner: owner, day: cal.startOfDay(for: day), kind: kind))
        replanMeals(owner, on: day)
    }

    private func pruneMealLogs() {
        let cutoff = PregnancyMath.addDays(-3, to: PregnancyMath.calendar.startOfDay(for: .now))
        mealLogs.removeAll { $0.date < cutoff }
    }

    /// Routine meal name → minute she finished it, for the engine.
    func eatenMinutes(_ owner: MedOwner, on day: Date) -> [String: Int] {
        let start = PregnancyMath.calendar.startOfDay(for: day)
        var result: [String: Int] = [:]
        for (kind, meal) in checkableMeals(owner, on: day) {
            guard let log = mealLog(owner, on: day, kind: kind) else { continue }
            result[meal.name] = Int(log.eatenAt.timeIntervalSince(start) / 60)
        }
        return result
    }

    // MARK: - Re-planning from meals (today only, no AI)

    private func mealInput(_ owner: MedOwner, on day: Date) -> (MealReplanInput, DayState, [UUID: MealAdjust])? {
        guard let s = dayState(owner, on: day) else { return nil }
        let eaten = eatenMinutes(owner, on: day)
        let existing = override(for: owner, on: day)?.adjusted ?? [:]
        var base = s.times
        var accepted: [UUID: Int] = [:]
        for (id, adjust) in existing where !s.fixed.contains(id) && s.times[id] != nil {
            base[id] = adjust.from
            // A fix she accepted stays while the meal that caused it is still logged.
            if adjust.reason == .late, eaten[adjust.meal] != nil { accepted[id] = s.times[id] }
        }
        var names = medicationNames
        for med in s.meds { names[med.id] = med.name }
        let rules = usableRules(owner, times: s.times, adjacent: s.adjacent)
        let input = MealReplanInput(routine: s.routine, eaten: eaten, times: base, fixed: s.fixed, meds: s.meds,
                                    rules: rules, range: s.range, accepted: accepted, names: names)
        return (input, s, existing)
    }

    /// Doses tied to a meal follow it quietly; a clash with a no-food rule becomes a card (taker's phone only).
    func replanMeals(_ owner: MedOwner, on day: Date = .now) {
        let cal = PregnancyMath.calendar
        guard cal.isDateInToday(day), hasRoutine(owner), case let (input, s, existing)? = mealInput(owner, on: day) else {
            saveAndReschedule()
            return
        }
        let result = MealReplan.compute(input)
        var adjusted: [UUID: MealAdjust] = [:]
        for (id, adjust) in existing where s.fixed.contains(id) { adjusted[id] = adjust }
        for (id, adjust) in existing where adjust.reason == .late && input.accepted[id] != nil { adjusted[id] = adjust }
        for (id, adjust) in result.follows { adjusted[id] = adjust }

        var pending: [UUID: Int] = [:]
        for med in s.meds { pending[med.id] = result.times[med.id] ?? s.times[med.id] }
        let timesChanged = s.meds.contains { pending[$0.id] != s.times[$0.id] }
        if timesChanged || adjusted != existing {
            writeMealOverride(owner, on: day, pending: pending, adjusted: adjusted)
            rebuildPlan()
        }
        saveAndReschedule()
    }

    /// After a pull: re-check this phone's own day (the partner's phone already moved what follows a meal).
    func replanOwnMealsAfterPull() {
        guard isShared else { return }
        let owner = viewerRole
        guard hasRoutine(owner), case let (input, s, existing)? = mealInput(owner, on: .now) else { return }
        let result = MealReplan.compute(input)
        var adjusted: [UUID: MealAdjust] = [:]
        for (id, adjust) in existing where s.fixed.contains(id) { adjusted[id] = adjust }
        for (id, adjust) in existing where adjust.reason == .late && input.accepted[id] != nil { adjusted[id] = adjust }
        for (id, adjust) in result.follows { adjusted[id] = adjust }
        var pending: [UUID: Int] = [:]
        for med in s.meds { pending[med.id] = result.times[med.id] ?? s.times[med.id] }
        guard s.meds.contains(where: { pending[$0.id] != s.times[$0.id] }) || adjusted != existing else { return }
        writeMealOverride(owner, on: .now, pending: pending, adjusted: adjusted)
        rebuildPlan()
    }

    /// Today's times with meal moves applied. Drops the override when nothing is left that differs from the routine.
    private func writeMealOverride(_ owner: MedOwner, on day: Date, pending: [UUID: Int], adjusted: [UUID: MealAdjust]) {
        let cal = PregnancyMath.calendar
        let start = cal.startOfDay(for: day)
        let list = instances(on: day).filter { $0.medication.owner == owner && $0.medication.managed }
        let existing = override(for: owner, on: day)
        var times = existing?.times ?? [:]
        for item in list {
            let id = item.medication.id
            if item.isPending, let m = pending[id] {
                times[id] = DoseTime(minutes: m)
            } else if times[id] == nil {
                times[id] = DoseTime(date: item.scheduledAt)
            }
        }
        overrides.removeAll { $0.owner == owner && cal.isDate($0.date, inSameDayAs: day) }
        let template = template(for: owner, on: day)
        let onlyMeals = existing.map { $0.meals == nil && $0.wake == nil && $0.bed == nil
            && ($0.templateID == nil || $0.templateID == template?.id) } ?? true
        let matchesRoutine = template.map { t in
            times.allSatisfy { id, time in t.dose(for: id).map { $0.time == time } ?? false }
        } ?? false
        if !(adjusted.isEmpty && onlyMeals && matchesRoutine) {
            overrides.append(DayOverride(
                id: existing?.id ?? UUID(), owner: owner, takerID: isShared ? memberID(for: owner) : nil,
                date: start, times: times, templateID: existing?.templateID ?? template?.id,
                meals: existing?.meals, wake: existing?.wake, bed: existing?.bed,
                adjusted: adjusted.isEmpty ? nil : adjusted
            ))
        }
        enqueue(.plan, owner.rawValue)
    }

    // MARK: - Clash cards

    /// Clashes shown on the taker's own phone (every person's on a phone that isn't shared).
    func refreshMealClashes() {
        var result: [MedOwner: [MealClash]] = [:]
        let owners: [MedOwner] = isShared ? [viewerRole] : MedOwner.allCases
        let acknowledged = acknowledgedMealClashes
        for owner in owners where hasRoutine(owner) && !eatenMinutes(owner, on: .now).isEmpty {
            guard let input = mealInput(owner, on: .now)?.0 else { continue }
            let clashes = MealReplan.compute(input).clashes.filter { !acknowledged.contains(Self.clashKey($0)) }
            if !clashes.isEmpty { result[owner] = clashes }
        }
        if result != mealClashes { mealClashes = result }
    }

    func acceptMealClash(_ clash: MealClash, owner: MedOwner) {
        guard let target = clash.target, case let (_, s, existing)? = mealInput(owner, on: .now) else { return }
        var adjusted = existing
        var pending: [UUID: Int] = [:]
        for med in s.meds { pending[med.id] = s.times[med.id] }
        let moves = clash.alsoMoves.merging([clash.medicationID: target]) { _, b in b }
        for (id, t) in moves where !s.fixed.contains(id) {
            let from = existing[id]?.from ?? s.times[id] ?? t
            pending[id] = t
            adjusted[id] = MealAdjust(reason: .late, meal: clash.meal, from: from)
        }
        writeMealOverride(owner, on: .now, pending: pending, adjusted: adjusted)
        rebuildPlan()
        replanMeals(owner)
    }

    /// "Keep 3:00": the card goes away for this meal log. A new log of that meal asks again.
    func keepMealClash(_ clash: MealClash) {
        var keys = acknowledgedMealClashes
        keys.insert(Self.clashKey(clash))
        acknowledgedMealClashes = keys
        refreshMealClashes()
    }

    private static func clashKey(_ clash: MealClash) -> String {
        "\(PlanDay.key(.now))|\(clash.id)"
    }

    /// Kept on this phone only, pruned after two days.
    private var acknowledgedMealClashes: Set<String> {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: "meds.keptMealClashes") as? [String: Double] ?? [:]
            let cutoff = Date.now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970
            return Set(raw.filter { $0.value > cutoff }.keys)
        }
        set {
            let raw = UserDefaults.standard.dictionary(forKey: "meds.keptMealClashes") as? [String: Double] ?? [:]
            let cutoff = Date.now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970
            var next: [String: Double] = raw.filter { $0.value > cutoff && newValue.contains($0.key) }
            for key in newValue where next[key] == nil { next[key] = Date.now.timeIntervalSince1970 }
            UserDefaults.standard.set(next, forKey: "meds.keptMealClashes")
        }
    }

    // MARK: - Captions

    /// Grey caption under a dose that moved for a meal: "Follows dinner" on her phone,
    /// "Prenatal AM moved to 3:30 · after a late lunch" on the partner's.
    func mealCaption(for instance: DoseInstance) -> String? {
        let med = instance.medication
        guard instance.isPending, PregnancyMath.calendar.isDateInToday(instance.scheduledAt),
              let adjust = override(for: med.owner, on: instance.scheduledAt)?.adjusted?[med.id] else { return nil }
        let meal = adjust.meal.lowercased()
        if !isShared || isMine(med) { return adjust.caption }
        let time = DayList.clock(instance.anchor)
        switch adjust.reason {
        case .late: return "\(med.shortName) moved to \(time) · after a late \(meal)"
        case .follows: return "\(med.shortName) moved to \(time) · follows \(meal)"
        case .with: return "\(med.shortName) moved to \(time) · with \(meal)"
        }
    }

    // MARK: - Remote merge

    func mergeRemoteMealLogs(_ remote: RemoteState) -> [MealLog] {
        func role(_ id: UUID) -> MedOwner { remote.members.first { $0.userID == id }?.role ?? .mom }
        let cutoff = PregnancyMath.addDays(-1, to: PregnancyMath.calendar.startOfDay(for: .now))
        var result = mealLogs.filter { $0.date < cutoff }
        var seen = Set<String>()
        for row in remote.mealLogs {
            guard let kind = MealKind(rawValue: row.meal), let date = SyncFormat.day(from: row.local_date) else { continue }
            let owner = role(row.taker_id)
            let key = SyncOp.mealKey(owner: owner, day: date, kind: kind)
            guard seen.insert(key).inserted else { continue }
            let local = mealLogs.first { SyncOp.mealKey(owner: $0.owner, day: $0.date, kind: $0.kind) == key }
            if hasPendingOp(.meal, key) {
                if let local { result.append(local) }
                continue
            }
            result.append(MealLog(id: row.id, owner: owner, date: date, kind: kind, plannedAt: row.planned_at,
                                  eatenAt: row.eaten_at, loggedBy: row.logged_by, updatedAt: row.updated_at ?? local?.updatedAt ?? .now))
        }
        for local in mealLogs where local.date >= cutoff {
            let key = SyncOp.mealKey(owner: local.owner, day: local.date, kind: local.kind)
            if !seen.contains(key), hasPendingOp(.meal, key) { result.append(local) }
        }
        return result.sorted(by: Self.mealOrder)
    }

    static func mealOrder(_ a: MealLog, _ b: MealLog) -> Bool {
        (a.date, a.owner.rawValue, a.kind.rawValue) < (b.date, b.owner.rawValue, b.kind.rawValue)
    }
}
