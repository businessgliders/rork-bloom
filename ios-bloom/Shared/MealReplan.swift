import Foundation

/// The four meals she can check off on Meds today.
nonisolated enum MealKind: String, Codable, CaseIterable, Hashable {
    case breakfast, lunch, dinner, snack

    /// The kind a routine meal's name stands for ("Supper" → dinner; anything unknown is a snack).
    static func of(_ name: String) -> MealKind {
        let n = name.lowercased()
        if n.contains("breakfast") || n.contains("brunch") { return .breakfast }
        if n.contains("lunch") { return .lunch }
        if n.contains("dinner") || n.contains("supper") { return .dinner }
        return .snack
    }

    var title: String { rawValue.capitalized }
}

/// Why a dose sits somewhere else today: it followed a meal she logged, or she accepted a fix after one.
nonisolated struct MealAdjust: Codable, Equatable, Hashable {
    enum Reason: String, Codable { case follows, with, late }
    var reason: Reason
    /// The routine meal's name ("Lunch").
    var meal: String
    /// Where the dose was before the meal moved it (minutes from midnight).
    var from: Int

    /// Stored in `planned_doses.meal_reason`: "follows:dinner:1260".
    var code: String { "\(reason.rawValue):\(meal):\(from)" }

    init(reason: Reason, meal: String, from: Int) {
        self.reason = reason
        self.meal = meal
        self.from = from
    }

    init?(code: String?) {
        guard let parts = code?.split(separator: ":", omittingEmptySubsequences: false), parts.count == 3,
              let reason = Reason(rawValue: String(parts[0])), let from = Int(parts[2]) else { return nil }
        self.init(reason: reason, meal: String(parts[1]), from: from)
    }

    /// Grey caption on her own phone: "Follows dinner" / "Moved with lunch" / "Moved after a late lunch".
    var caption: String {
        let meal = meal.lowercased()
        switch reason {
        case .follows: return "Follows \(meal)"
        case .with: return "Moved with \(meal)"
        case .late: return "Moved after \(meal)"
        }
    }
}

/// A logged meal that breaks a no-food rule, with the fix to offer.
nonisolated struct MealClash: Equatable, Identifiable {
    var medicationID: UUID
    var meal: String
    var eatenAt: Int
    var plannedEnd: Int?
    var rule: ScheduleRule
    var from: Int
    /// The earliest time that keeps every rule, or nil when nothing does.
    var to: Int?
    /// When nothing keeps every rule: the time that breaks them the least.
    var leastBad: Int?
    /// Other doses that have to move too for `to` to work.
    var alsoMoves: [UUID: Int]
    var noFoodUntilBefore: Int
    var noFoodUntilAfter: Int?
    var title: String
    var sentence: String
    var fitLine: String

    var id: String { "\(medicationID.uuidString)|\(meal.lowercased())|\(eatenAt)" }
    var target: Int? { to ?? leastBad }
}

nonisolated struct MealReplanInput {
    /// The planned routine for the day (before any meal was logged).
    var routine: EngineRoutine
    /// Routine meal name → minute she finished eating.
    var eaten: [String: Int]
    /// Every dose's planned minute today, before meal moves (taken doses at their taken minute).
    var times: [UUID: Int]
    /// Taken doses: never move.
    var fixed: Set<UUID>
    /// Pending doses.
    var meds: [EngineMed]
    /// Usable rules, day bounds included.
    var rules: [ScheduleRule]
    /// Where a pending dose can go (now … bed).
    var range: ClosedRange<Int>
    /// Doses she already moved after a clash today (kept where she put them).
    var accepted: [UUID: Int] = [:]
    var names: [UUID: String] = [:]
}

nonisolated struct MealReplanResult: Equatable {
    var times: [UUID: Int]
    var follows: [UUID: MealAdjust]
    var clashes: [MealClash]
}

/// Same-day re-planning from the meals she actually ate. Deterministic: no AI, same input gives same output.
/// A logged meal's time is when she finished; the meal keeps its routine length.
nonisolated enum MealReplan {
    /// The day's routine with each eaten meal moved to when she actually ate it.
    static func actualRoutine(_ routine: EngineRoutine, eaten: [String: Int]) -> EngineRoutine {
        let meals = routine.meals.map { meal -> EngineMeal in
            guard let end = eaten[meal.name] else { return meal }
            return EngineMeal(name: meal.name, start: end - meal.duration, duration: meal.duration)
        }
        return EngineRoutine(wake: routine.wake, bed: routine.bed, meals: meals, adjacent: routine.adjacent)
    }

    static func compute(_ input: MealReplanInput) -> MealReplanResult {
        let actual = actualRoutine(input.routine, eaten: input.eaten)
        var times = input.times
        var follows: [UUID: MealAdjust] = [:]
        for (id, t) in input.accepted where !input.fixed.contains(id) { times[id] = t }

        // 1. Doses tied to a meal ("with lunch", "within 1 h after dinner") follow it quietly.
        for med in ScheduleEngine.order(input.meds, rules: input.rules) {
            let id = med.id
            guard !input.fixed.contains(id), med.pinned == nil, input.accepted[id] == nil,
                  let base = input.times[id] else { continue }
            guard let rule = input.rules.first(where: { rule in
                guard rule.subjectID == id, rule.target == .meal,
                      let planned = input.routine.meal(named: rule.targetMeal) else { return false }
                return input.eaten[planned.name] != nil
            }), let planned = input.routine.meal(named: rule.targetMeal),
                  let moved = actual.meal(named: planned.name) else { continue }
            let delta = moved.start - planned.start
            guard delta != 0 else { continue }
            let wanted = base + delta
            var candidate = times
            candidate[id] = wanted
            let fitsWanted = input.range.contains(wanted) && input.rules.filter { $0.involves(id) }
                .allSatisfy { (ScheduleEngine.deficit($0, times: candidate, routine: actual) ?? 0) == 0 }
            let newTime = fitsWanted ? wanted
                : ScheduleEngine.closestValid(for: id, near: wanted, times: times, routine: actual, rules: input.rules, range: input.range)
            guard let newTime, newTime != base else { continue }
            times[id] = newTime
            let reason: MealAdjust.Reason = (rule.relation == .with || rule.relation == .at) ? .with : .follows
            follows[id] = MealAdjust(reason: reason, meal: planned.name, from: base)
        }

        // 2. A logged meal inside a no-food window: offer the earliest time that keeps every rule.
        var clashes: [MealClash] = []
        for med in input.meds where !input.fixed.contains(med.id) {
            let id = med.id
            guard let t = times[id] else { continue }
            for rule in input.rules where rule.subjectID == id && rule.isNoFood {
                guard let d = ScheduleEngine.deficit(rule, times: times, routine: actual), d > 0,
                      let meal = actual.meals.first(where: { input.eaten[$0.name] != nil && overlaps(rule, t: t, meal: $0) })
                else { continue }
                clashes.append(clash(for: id, rule: rule, meal: meal, t: t, times: times, actual: actual, input: input))
                break
            }
        }
        return MealReplanResult(times: times, follows: follows, clashes: clashes)
    }

    /// Whether this meal falls inside the dose's no-food window.
    static func overlaps(_ rule: ScheduleRule, t: Int, meal: EngineMeal) -> Bool {
        let x = rule.minMinutes ?? 0
        let after = meal.start < t + x && meal.end > t          // no food for x after the dose
        let before = meal.start < t && meal.end > t - x         // no food for x before the dose
        switch rule.relation {
        case .before: return after
        case .after: return before
        case .apart: return after || before
        default: return false
        }
    }

    /// Minutes of no food the dose needs afterwards.
    static func noFoodAfter(_ id: UUID, rules: [ScheduleRule]) -> Int {
        rules.filter { $0.subjectID == id && $0.target == .food && ($0.relation == .before || $0.relation == .apart) }
            .map { $0.minMinutes ?? 0 }.max() ?? 0
    }

    private static func clash(for id: UUID, rule: ScheduleRule, meal: EngineMeal, t: Int, times: [UUID: Int],
                              actual: EngineRoutine, input: MealReplanInput) -> MealClash {
        let relevant = input.rules.filter { $0.involves(id) }
        func fits(_ m: Int) -> Bool {
            var c = times
            c[id] = m
            return relevant.allSatisfy { (ScheduleEngine.deficit($0, times: c, routine: actual) ?? 0) == 0 }
        }
        let lower = ScheduleEngine.roundUp(input.range.lowerBound)
        let upper = input.range.upperBound
        var to: Int?
        var alsoMoves: [UUID: Int] = [:]
        // Earliest later time with everything else unchanged, then anywhere today.
        var m = max(ScheduleEngine.roundUp(t), lower)
        while m <= upper, to == nil { if fits(m) { to = m }; m += ScheduleEngine.step }
        if to == nil {
            m = lower
            while m <= upper, to == nil { if fits(m) { to = m }; m += ScheduleEngine.step }
        }
        // Let the other pending doses settle around it.
        if to == nil {
            let locked = input.fixed.union([id]).union(input.meds.filter { $0.pinned != nil }.map(\.id))
            let open = input.rules.filter { r in
                !locked.contains(r.subjectID) || (r.targetMedicationID.map { !locked.contains($0) } ?? false) || r.involves(id)
            }
            m = max(ScheduleEngine.roundUp(t), lower)
            while m <= upper, to == nil {
                var c = times
                c[id] = m
                let settled = ScheduleEngine.settle(times: c, locked: locked, meds: input.meds, routine: actual, rules: input.rules, range: input.range)
                if open.allSatisfy({ (ScheduleEngine.deficit($0, times: settled, routine: actual) ?? 0) == 0 }) {
                    to = m
                    for (other, v) in settled where other != id && times[other] != v { alsoMoves[other] = v }
                }
                m += 15
            }
        }
        // Nothing keeps every rule: the time that breaks them the least.
        var leastBad: Int?
        if to == nil {
            var best: (total: Int, time: Int)?
            m = lower
            while m <= upper {
                var c = times
                c[id] = m
                let total = relevant.reduce(0) { $0 + (ScheduleEngine.deficit($1, times: c, routine: actual) ?? 0) }
                if best == nil || total < best!.total { best = (total, m) }
                m += ScheduleEngine.step
            }
            if let best, best.time != t { leastBad = best.time }
        }

        let name = input.names[id] ?? "This dose"
        let mealName = meal.name.lowercased()
        let planned = input.routine.meal(named: meal.name)
        let eaten = meal.end
        let when: String
        if let planned, eaten > planned.end + 10 { when = "Late \(mealName)" }
        else if let planned, eaten < planned.end - 10 { when = "Early \(mealName)" }
        else { when = meal.name }
        let x = rule.minMinutes ?? 0
        let gap: String
        if eaten <= t { gap = "\(meal.name) ended at \(ScheduleEngine.clock(eaten)), \(ScheduleEngine.duration(t - eaten)) before \(ScheduleEngine.clock(t))." }
        else if meal.start >= t { gap = "\(meal.name) started \(ScheduleEngine.duration(meal.start - t)) after \(ScheduleEngine.clock(t))." }
        else { gap = "\(meal.name) at \(ScheduleEngine.clock(eaten)) runs over \(ScheduleEngine.clock(t))." }
        let need: String
        switch rule.relation {
        case .before: need = "no food for \(ScheduleEngine.duration(x)) after it"
        case .after: need = "no food for \(ScheduleEngine.duration(x)) before it"
        default: need = "no food for \(ScheduleEngine.duration(x)) before or after it"
        }
        let sentence = "\(name) needs \(need). \(gap)"

        let after = noFoodAfter(id, rules: input.rules)
        let fitLine: String
        if let to {
            if alsoMoves.isEmpty {
                let nextMeal = actual.meals.first { $0.start >= to && input.eaten[$0.name] == nil }
                let laterMeds = input.meds.contains { $0.id != id && (times[$0.id] ?? 0) > to }
                switch (nextMeal, laterMeds) {
                case let (meal?, true): fitLine = "\(meal.name) at \(ScheduleEngine.clock(meal.start)) and the later meds still fit."
                case let (meal?, false): fitLine = "\(meal.name) at \(ScheduleEngine.clock(meal.start)) still fits."
                case (nil, true): fitLine = "The later meds still fit."
                case (nil, false): fitLine = "Everything else stays as planned."
                }
            } else {
                fitLine = alsoMoves.sorted { $0.value < $1.value }
                    .map { "\(input.names[$0.key] ?? "A dose") moves to \(ScheduleEngine.clock($0.value))" }
                    .joined(separator: ", ") + " too."
            }
        } else {
            fitLine = "No time left today keeps every rule."
        }

        return MealClash(
            medicationID: id, meal: meal.name, eatenAt: eaten, plannedEnd: planned?.end, rule: rule, from: t,
            to: to, leastBad: leastBad, alsoMoves: alsoMoves,
            noFoodUntilBefore: t + after, noFoodUntilAfter: (to ?? leastBad).map { $0 + after },
            title: "\(when) affects \(name)",
            sentence: sentence, fitLine: fitLine
        )
    }
}
