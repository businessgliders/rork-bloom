import Foundation

/// A meal on the engine's minute axis.
nonisolated struct EngineMeal: Equatable {
    var name: String
    var start: Int
    var duration: Int
    var end: Int { start + duration }
}

/// Wake, bed and meals in minutes from midnight. Meals are fixed; the engine places medications around them.
nonisolated struct EngineRoutine: Equatable {
    var wake: Int
    var bed: Int
    var meals: [EngineMeal]

    init(wake: Int, bed: Int, meals: [EngineMeal]) {
        self.wake = wake
        self.bed = bed
        self.meals = meals.sorted { $0.start < $1.start }
    }

    init(_ template: ScheduleTemplate) {
        self.init(
            wake: template.wake.minutesFromMidnight,
            bed: template.bed.minutesFromMidnight,
            meals: template.meals.map { EngineMeal(name: $0.name, start: $0.time.minutesFromMidnight, duration: $0.durationMinutes) }
        )
    }

    /// The meal a rule names: exact name first, then a name that contains it ("lunch" → "Lunch").
    func meal(named name: String?) -> EngineMeal? {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        return meals.first { $0.name.lowercased() == name }
            ?? meals.first { $0.name.lowercased().contains(name) || name.contains($0.name.lowercased()) }
    }
}

nonisolated struct EngineMed: Equatable {
    var id: UUID
    var name: String
    /// A time the user stated; never moved.
    var pinned: Int?
}

/// A rule that the current times break, in words, with the closest fix.
nonisolated struct RuleViolation: Identifiable, Equatable {
    var rule: ScheduleRule
    /// "Iron is now 3 h after Thyroid; your rule is 4 h"
    var message: String
    /// "Closest fix: take Iron at 11:00."
    var fix: String?
    var deficit: Int
    var id: UUID { rule.id }
}

nonisolated struct ScheduleResult: Equatable {
    var times: [UUID: Int]
    var violations: [RuleViolation]
}

/// Deterministic placement of medications in a routine. No AI: the same routine and rules
/// always give the same times.
nonisolated enum ScheduleEngine {
    static let step = 5

    // MARK: Generate

    /// Places each medication at the earliest time (5-minute steps, wake to bed) that satisfies all of its rules.
    /// - `fixed`: times that can't move (already taken today, or kept by the caller).
    /// - `earliest`: nothing new goes before this minute (recalculating from "now").
    /// When no time satisfies every rule, the time breaking the fewest rules by the least is used and each broken rule is reported.
    static func generate(routine: EngineRoutine, meds: [EngineMed], rules: [ScheduleRule],
                         fixed: [UUID: Int] = [:], earliest: Int? = nil) -> ScheduleResult {
        let names = Dictionary(meds.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let medIDs = Set(meds.map(\.id)).union(fixed.keys)
        let usable = rules.filter { medIDs.contains($0.subjectID) && ($0.target != .medication || medIDs.contains($0.targetMedicationID ?? UUID())) }
        var times = fixed

        let lower = roundUp(max(routine.wake, earliest ?? routine.wake))
        let upper = max(routine.bed, lower)

        for med in order(meds, rules: usable) where times[med.id] == nil {
            if let pinned = med.pinned {
                times[med.id] = pinned
                continue
            }
            let relevant = usable.filter { $0.involves(med.id) }
            var best: (count: Int, total: Int, time: Int)?
            var t = lower
            while t <= upper {
                var candidate = times
                candidate[med.id] = t
                var count = 0
                var total = 0
                for rule in relevant {
                    if let d = deficit(rule, times: candidate, routine: routine), d > 0 {
                        count += 1
                        total += d
                    }
                }
                if count == 0 {
                    best = (0, 0, t)
                    break
                }
                if best == nil || (count, total) < (best!.count, best!.total) { best = (count, total, t) }
                t += step
            }
            times[med.id] = best?.time ?? lower
        }
        // Rules only about doses that can't move anymore (already taken) are history, not something to fix.
        let placed = Set(meds.map(\.id)).subtracting(fixed.keys)
        let open = usable.filter { placed.contains($0.subjectID) || placed.contains($0.targetMedicationID ?? UUID()) }
        return ScheduleResult(times: times, violations: violations(times: times, routine: routine, rules: open, names: names))
    }

    /// Medications in an order where each comes after the ones its rules depend on (input order otherwise).
    static func order(_ meds: [EngineMed], rules: [ScheduleRule]) -> [EngineMed] {
        let ids = Set(meds.map(\.id))
        var deps: [UUID: Set<UUID>] = [:]
        for rule in rules where rule.target == .medication && rule.relation != .apart {
            guard let target = rule.targetMedicationID, ids.contains(target), target != rule.subjectID else { continue }
            deps[rule.subjectID, default: []].insert(target)
        }
        var placed = Set<UUID>()
        var result: [EngineMed] = []
        var remaining = meds
        while !remaining.isEmpty {
            if let index = remaining.firstIndex(where: { deps[$0.id, default: []].isSubset(of: placed) }) {
                let med = remaining.remove(at: index)
                placed.insert(med.id)
                result.append(med)
            } else {
                // A cycle: keep the user's order for what's left.
                result.append(contentsOf: remaining)
                break
            }
        }
        return result
    }

    // MARK: Checking

    /// Every rule the given times break.
    static func violations(times: [UUID: Int], routine: EngineRoutine, rules: [ScheduleRule], names: [UUID: String]) -> [RuleViolation] {
        rules.compactMap { rule in
            guard let d = deficit(rule, times: times, routine: routine), d > 0 else { return nil }
            return explain(rule, times: times, routine: routine, names: names, deficit: d)
        }
    }

    /// How many minutes a rule is off by (0 = satisfied), or nil when it can't be checked yet.
    static func deficit(_ rule: ScheduleRule, times: [UUID: Int], routine: EngineRoutine) -> Int? {
        guard let t = times[rule.subjectID] else { return nil }
        let minV = rule.minMinutes ?? 0
        func range(_ d: Int) -> Int {
            if d < minV { return minV - d }
            if let maxV = rule.maxMinutes, d > maxV { return d - maxV }
            return 0
        }

        switch rule.target {
        case .medication:
            guard let id = rule.targetMedicationID, let other = times[id] else { return nil }
            switch rule.relation {
            case .after: return range(t - other)
            case .before: return range(other - t)
            case .apart: return max(0, minV - abs(t - other))
            case .with: return abs(t - other)
            case .at: return abs(t - (other + minV))
            }

        case .food:
            switch rule.relation {
            case .before: return noFoodAfter(t, minutes: minV, routine: routine)
            case .after: return noFoodBefore(t, minutes: minV, routine: routine)
            case .apart: return max(noFoodAfter(t, minutes: minV, routine: routine), noFoodBefore(t, minutes: minV, routine: routine))
            case .with, .at:
                guard !routine.meals.isEmpty else { return nil }
                return routine.meals.map { distance(t, toMeal: $0) }.min() ?? 0
            }

        case .meal:
            guard let meal = routine.meal(named: rule.targetMeal) else {
                // Unknown meal name: "with food" is the closest reading.
                guard !routine.meals.isEmpty else { return nil }
                return routine.meals.map { distance(t, toMeal: $0) }.min() ?? 0
            }
            switch rule.relation {
            case .with: return distance(t, toMeal: meal)
            case .at: return abs(t - (meal.start + minV))
            case .before: return range(meal.start - t)
            case .after: return range(t - meal.end)
            case .apart: return max(0, minV - min(abs(t - meal.start), abs(t - meal.end)))
            }

        case .wake:
            switch rule.relation {
            case .at, .with, .before: return abs(t - (routine.wake + minV))
            case .after, .apart: return range(t - routine.wake)
            }

        case .bed:
            switch rule.relation {
            case .at, .with, .after: return abs(t - (routine.bed - minV))
            case .before, .apart: return range(routine.bed - t)
            }
        }
    }

    /// "No food for `minutes` after the dose": no meal may overlap [t, t + minutes).
    private static func noFoodAfter(_ t: Int, minutes: Int, routine: EngineRoutine) -> Int {
        routine.meals.map { meal -> Int in
            guard meal.start < t + minutes, meal.end > t else { return 0 }
            return meal.start > t ? t + minutes - meal.start : min(meal.end - t, t + minutes - meal.start)
        }.max() ?? 0
    }

    /// "No food for `minutes` before the dose": no meal may overlap (t − minutes, t).
    private static func noFoodBefore(_ t: Int, minutes: Int, routine: EngineRoutine) -> Int {
        routine.meals.map { meal -> Int in
            guard meal.start < t, meal.end > t - minutes else { return 0 }
            return meal.end - (t - minutes)
        }.max() ?? 0
    }

    private static func distance(_ t: Int, toMeal meal: EngineMeal) -> Int {
        if t < meal.start { return meal.start - t }
        if t > meal.end { return t - meal.end }
        return 0
    }

    // MARK: Words

    private static func explain(_ rule: ScheduleRule, times: [UUID: Int], routine: EngineRoutine, names: [UUID: String], deficit: Int) -> RuleViolation {
        let subject = names[rule.subjectID] ?? "This medication"
        let t = times[rule.subjectID] ?? 0
        let minV = rule.minMinutes ?? 0
        var message = "\(subject) breaks a rule: \(describe(rule, names: names))"
        var fix: String?

        switch rule.target {
        case .medication:
            let target = rule.targetMedicationID.flatMap { names[$0] } ?? "the other medication"
            let other = rule.targetMedicationID.flatMap { times[$0] } ?? t
            switch rule.relation {
            case .after, .before:
                let d = rule.relation == .after ? t - other : other - t
                let word = rule.relation.rawValue
                let actual = d >= 0 ? "\(duration(d)) \(word)" : "\(duration(-d)) \(rule.relation == .after ? "before" : "after")"
                if d < minV {
                    message = "\(subject) is now \(actual) \(target); your rule is \(duration(minV))"
                    let goal = rule.relation == .after ? other + minV : other - minV
                    fix = "Closest fix: take \(subject) at \(clock(goal)), or change the rule to \(duration(max(d, 0)))."
                } else if let maxV = rule.maxMinutes {
                    message = "\(subject) is now \(actual) \(target); your rule is at most \(duration(maxV))"
                    let goal = rule.relation == .after ? other + maxV : other - maxV
                    fix = "Closest fix: take \(subject) at \(clock(goal))."
                }
            case .apart:
                message = "\(subject) and \(target) are now \(duration(abs(t - other))) apart; your rule is \(duration(minV))"
                let goal = t >= other ? other + minV : other - minV
                fix = "Closest fix: take \(subject) at \(clock(goal)), or change the rule to \(duration(abs(t - other)))."
            case .with, .at:
                message = "\(subject) is now at \(clock(t)), not with \(target) at \(clock(other))"
                fix = "Closest fix: take \(subject) at \(clock(other + (rule.relation == .at ? minV : 0)))."
            }

        case .food:
            switch rule.relation {
            case .before, .apart:
                if let meal = routine.meals.first(where: { $0.start < t + minV && $0.end > t }) {
                    if meal.start > t {
                        message = "\(subject) is now \(duration(meal.start - t)) before \(meal.name); your rule is no food for \(duration(minV)) after it"
                        fix = "Closest fix: move \(meal.name) to \(clock(t + minV)), or take \(subject) at \(clock(meal.start - minV))."
                    } else {
                        message = "\(subject) is now during \(meal.name); your rule is no food for \(duration(minV)) after it"
                        fix = "Closest fix: take \(subject) at \(clock(meal.start - minV))."
                    }
                    break
                }
                fallthrough
            case .after:
                if let meal = routine.meals.first(where: { $0.start < t && $0.end > t - minV }) {
                    if meal.end <= t {
                        message = "\(subject) is now \(duration(t - meal.end)) after \(meal.name) ends; your rule is no food for \(duration(minV)) before it"
                    } else {
                        message = "\(subject) is now during \(meal.name); your rule is no food for \(duration(minV)) before it"
                    }
                    fix = "Closest fix: take \(subject) at \(clock(meal.end + minV))."
                }
            case .with, .at:
                let nearest = routine.meals.min { distance(t, toMeal: $0) < distance(t, toMeal: $1) }
                message = "\(subject) is now at \(clock(t)), not with a meal"
                if let nearest { fix = "Closest fix: take \(subject) at \(clock(nearest.start)) with \(nearest.name)." }
            }

        case .meal:
            let meal = routine.meal(named: rule.targetMeal)
            let mealName = meal?.name ?? rule.targetMeal ?? "the meal"
            if let meal {
                switch rule.relation {
                case .with:
                    message = "\(subject) is now at \(clock(t)), not with \(mealName) (\(clock(meal.start))–\(clock(meal.end)))"
                    fix = "Closest fix: take \(subject) at \(clock(meal.start))."
                case .at:
                    message = "\(subject) is now at \(clock(t)); your rule puts it at \(clock(meal.start + minV))"
                    fix = "Closest fix: take \(subject) at \(clock(meal.start + minV))."
                case .before:
                    let d = meal.start - t
                    message = "\(subject) is now \(d >= 0 ? duration(d) + " before" : duration(-d) + " after the start of") \(mealName); your rule is \(rule.maxMinutes != nil && d > (rule.maxMinutes ?? 0) ? "at most \(duration(rule.maxMinutes ?? 0))" : duration(minV)) before"
                    fix = "Closest fix: take \(subject) at \(clock(meal.start - minV)), or move \(mealName) to \(clock(t + minV))."
                case .after:
                    let d = t - meal.end
                    message = "\(subject) is now \(d >= 0 ? duration(d) + " after" : duration(-d) + " before the end of") \(mealName); your rule is \(rule.maxMinutes != nil && d > (rule.maxMinutes ?? 0) ? "at most \(duration(rule.maxMinutes ?? 0))" : duration(minV)) after"
                    fix = "Closest fix: take \(subject) at \(clock(meal.end + minV))."
                case .apart:
                    message = "\(subject) is now too close to \(mealName); your rule is \(duration(minV)) apart"
                }
            } else {
                message = "\(subject) is now at \(clock(t)), not with a meal"
            }

        case .wake:
            let goal = routine.wake + minV
            message = "\(subject) is now at \(clock(t)); your rule puts it at \(clock(goal)) (\(minV == 0 ? "on waking" : "\(duration(minV)) after waking"))"
            fix = "Closest fix: take \(subject) at \(clock(goal))."
            if rule.relation == .after, let maxV = rule.maxMinutes, t - routine.wake > maxV {
                message = "\(subject) is now \(duration(t - routine.wake)) after waking; your rule is at most \(duration(maxV))"
                fix = "Closest fix: take \(subject) at \(clock(routine.wake + maxV))."
            } else if rule.relation == .after {
                message = "\(subject) is now \(duration(max(0, t - routine.wake))) after waking; your rule is \(duration(minV))"
            }

        case .bed:
            let goal = routine.bed - minV
            message = rule.relation == .before
                ? "\(subject) is now \(duration(max(0, routine.bed - t))) before bed; your rule is \(duration(minV))"
                : "\(subject) is now at \(clock(t)); your rule puts it at \(clock(goal))"
            fix = "Closest fix: take \(subject) at \(clock(goal))."
        }
        return RuleViolation(rule: rule, message: message, fix: fix, deficit: deficit)
    }

    /// "Iron · at least 4 h after Thyroid". Uses the rule's own numbers only.
    static func describe(_ rule: ScheduleRule, names: [UUID: String], includeSubject: Bool = true) -> String {
        let subject = names[rule.subjectID] ?? "Medication"
        let minV = rule.minMinutes ?? 0
        let target = rule.targetMedicationID.flatMap { names[$0] } ?? "another medication"
        let meal = (rule.targetMeal ?? "meal").lowercased()
        func gap(_ word: String, _ what: String) -> String {
            if let maxV = rule.maxMinutes, rule.minMinutes != nil, minV > 0 {
                return "\(duration(minV))–\(duration(maxV)) \(word) \(what)"
            }
            if let maxV = rule.maxMinutes { return "at most \(duration(maxV)) \(word) \(what)" }
            return minV == 0 ? "\(word) \(what)" : "at least \(duration(minV)) \(word) \(what)"
        }
        let text: String
        switch (rule.target, rule.relation) {
        case (.medication, .after): text = gap("after", target)
        case (.medication, .before): text = gap("before", target)
        case (.medication, .apart): text = "at least \(duration(minV)) apart from \(target)"
        case (.medication, .with): text = "together with \(target)"
        case (.medication, .at): text = minV == 0 ? "together with \(target)" : "\(duration(minV)) after \(target)"
        case (.food, .before): text = "no food for \(duration(minV)) after"
        case (.food, .after): text = "no food for \(duration(minV)) before"
        case (.food, .apart): text = "no food for \(duration(minV)) before or after"
        case (.food, _): text = "with food"
        case (.meal, .with): text = "with \(meal)"
        case (.meal, .at): text = minV == 0 ? "at the start of \(meal)" : "\(duration(minV)) into \(meal)"
        case (.meal, .before): text = gap("before", meal)
        case (.meal, .after): text = gap("after", meal)
        case (.meal, .apart): text = "at least \(duration(minV)) apart from \(meal)"
        case (.wake, .after): text = rule.maxMinutes != nil ? gap("after", "waking up") : (minV == 0 ? "after waking up" : "\(duration(minV)) after waking up")
        case (.wake, _): text = minV == 0 ? "as soon as you wake up" : "\(duration(minV)) after waking up"
        case (.bed, .before): text = minV == 0 ? "before bed" : "at least \(duration(minV)) before bed"
        case (.bed, _): text = minV == 0 ? "at bedtime" : "\(duration(minV)) before bed"
        }
        return includeSubject ? "\(subject) · \(text)" : text
    }

    // MARK: Editing

    /// Moves the item at `index` and everything after it by `delta`, keeping the gaps.
    static func shift(_ times: [Int], from index: Int, by delta: Int) -> [Int] {
        times.enumerated().map { $0.offset >= index ? $0.element + delta : $0.element }
    }

    /// New time for an item moved from `source` to `destination` in a time-ordered list:
    /// halfway between its new neighbours, on a 5-minute step.
    static func timeAfterMove(_ times: [Int], from source: Int, to destination: Int) -> Int {
        var rest = times
        let moved = rest.remove(at: source)
        let insert = min(max(destination > source ? destination - 1 : destination, 0), rest.count)
        let previous = insert > 0 ? rest[insert - 1] : nil
        let next = insert < rest.count ? rest[insert] : nil
        switch (previous, next) {
        case let (p?, n?): return roundNearest((p + n) / 2)
        case let (p?, nil): return roundNearest(p + 30)
        case let (nil, n?): return roundNearest(n - 30)
        default: return moved
        }
    }

    // MARK: Helpers

    static func roundUp(_ minutes: Int) -> Int { Int((Double(minutes) / Double(step)).rounded(.up)) * step }
    static func roundNearest(_ minutes: Int) -> Int { Int((Double(minutes) / Double(step)).rounded()) * step }

    static func duration(_ minutes: Int) -> String { minutes == 0 ? "0 min" : Medication.durationText(minutes) }

    /// "7:00 AM" style in the user's locale. Minutes outside one day wrap.
    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return DoseTime(hour: m / 60, minute: m % 60).date(on: Date(timeIntervalSince1970: 1_700_000_000))
            .formatted(date: .omitted, time: .shortened)
    }
}

extension DoseTime {
    nonisolated init(minutes: Int) {
        let m = ((minutes % 1440) + 1440) % 1440
        self.init(hour: m / 60, minute: m % 60)
    }
}
