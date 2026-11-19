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
    /// Doses on the neighbouring days on the same minute axis: the day before is negative (−1440…0),
    /// the day after is past 1440. Gap rules ("10 h apart") are checked against these too, so the
    /// schedule works as one continuous cycle across midnight.
    var adjacent: [UUID: [Int]]
    /// The day after follows the same times as this day (the routine continues into itself, or tomorrow
    /// follows today's routine unchanged): a dose that moves today moves tomorrow too, so its next-day copy
    /// is its own time + 1440 rather than the stored one. Without this, a stale copy of the old time keeps
    /// breaking an overnight gap after the dose has moved.
    var mirrorNext = false
    /// The same for the day before (only for a routine as a whole; a real day keeps what was actually taken).
    var mirrorPrevious = false

    init(wake: Int, bed: Int, meals: [EngineMeal], adjacent: [UUID: [Int]] = [:], mirrorNext: Bool = false, mirrorPrevious: Bool = false) {
        self.wake = wake
        self.bed = bed
        self.meals = meals.sorted { $0.start < $1.start }
        self.adjacent = adjacent
        self.mirrorNext = mirrorNext
        self.mirrorPrevious = mirrorPrevious
    }

    init(_ template: ScheduleTemplate, adjacent: [UUID: [Int]] = [:], mirror: Bool = false) {
        self.init(
            wake: template.wake.minutesFromMidnight,
            bed: template.bed.minutesFromMidnight,
            meals: template.meals.map { EngineMeal(name: $0.name, start: $0.time.minutesFromMidnight, duration: $0.durationMinutes) },
            adjacent: adjacent,
            mirrorNext: mirror,
            mirrorPrevious: mirror
        )
    }

    /// A medication's doses on the neighbouring days, on this day's axis.
    func neighbours(_ id: UUID, times: [UUID: Int]) -> [Int] {
        var list = adjacent[id] ?? []
        guard let t = times[id] else { return list }
        if mirrorNext {
            list.removeAll { $0 >= 1440 }
            list.append(t + 1440)
        }
        if mirrorPrevious {
            list.removeAll { $0 < 0 }
            list.append(t - 1440)
        }
        return list
    }

    /// Neighbour-day minutes from the day before's and the day after's times (each in 0..<1440).
    static func adjacent(previous: [UUID: [Int]], next: [UUID: [Int]]) -> [UUID: [Int]] {
        var result: [UUID: [Int]] = [:]
        for (id, list) in previous { result[id, default: []] += list.map { $0 - 1440 } }
        for (id, list) in next { result[id, default: []] += list.map { $0 + 1440 } }
        return result.mapValues { Array(Set($0)).sorted() }
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

/// A one-tap way out of a broken rule. Every fix is checked to keep all rules of the item it changes.
nonisolated struct ScheduleFix: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Put a medication at this minute.
        case move(UUID, Int)
        /// Leave a medication out today.
        case skip(UUID)
        /// Change the routine itself (bedtime, wake-up or one meal) and re-place doses to fit.
        case retime(RoutineTweak)
    }

    struct RoutineTweak: Equatable {
        var wake: Int?
        var bed: Int?
        var mealName: String?
        var mealStart: Int?
        /// Every dose's minute after the change.
        var times: [UUID: Int]
    }

    /// "Move Iron to 1:30 PM", "Take Thyroid 30 min earlier", "Skip Iron today"
    var title: String
    var kind: Kind
    var id: String { title }
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
        let usable = rules.filter { applies($0, on: medIDs, routine: routine) }
        var times = fixed

        let lower = roundUp(max(routine.wake, earliest ?? routine.wake))
        let upper = max(routine.bed, lower)

        for med in order(meds, rules: usable) where times[med.id] == nil {
            if let pinned = med.pinned {
                times[med.id] = pinned
                continue
            }
            let relevant = usable.filter { $0.involves(med.id) }
            // Anchors ("at bedtime", "with lunch") win over gaps: when both can't hold, the dose stays on its
            // anchor and the gap is reported, so the other dose moves instead (PM stays at bedtime, AM waits).
            var best: (anchor: Int, count: Int, total: Int, time: Int)?
            var t = lower
            while t <= upper {
                var candidate = times
                candidate[med.id] = t
                var anchor = 0
                var count = 0
                var total = 0
                for rule in relevant {
                    if let d = deficit(rule, times: candidate, routine: routine), d > 0 {
                        if rule.subjectID == med.id, isAnchor(rule) { anchor += d }
                        count += 1
                        total += d
                    }
                }
                if count == 0 {
                    best = (0, 0, 0, t)
                    break
                }
                if best == nil || (anchor, count, total) < (best!.anchor, best!.count, best!.total) { best = (anchor, count, total, t) }
                t += step
            }
            times[med.id] = best?.time ?? lower
        }
        // Doses tied by a gap rule ("AM and PM 12 h apart") that one-at-a-time placement can't satisfy: place
        // them together, at the pair closest to where they landed that keeps every rule of both.
        let pinnedIDs = Set(meds.compactMap { $0.pinned == nil ? nil : $0.id })
        let movable = Set(meds.map(\.id)).subtracting(fixed.keys).subtracting(pinnedIDs)
        times = placeLinked(times: times, movable: movable, routine: routine, rules: usable, range: lower...upper)
        // Rules only about doses that can't move anymore (already taken) are history, not something to fix.
        let placed = Set(meds.map(\.id)).subtracting(fixed.keys)
        let open = usable.filter { placed.contains($0.subjectID) || placed.contains($0.targetMedicationID ?? UUID()) }
        return ScheduleResult(times: times, violations: violations(times: times, routine: routine, rules: open, names: names))
    }

    /// "At waking", "at bedtime", "with lunch", "with food": a fixed point in her day.
    static func isAnchor(_ rule: ScheduleRule) -> Bool {
        (rule.relation == .at || rule.relation == .with) && rule.target != .medication
    }

    /// Whether a rule can be checked on a day with these medications: both sides on the day, or for a gap
    /// rule ("apart") one side on the day and the other on a neighbouring day.
    static func applies(_ rule: ScheduleRule, on ids: Set<UUID>, routine: EngineRoutine) -> Bool {
        guard rule.target == .medication else { return ids.contains(rule.subjectID) }
        let target = rule.targetMedicationID ?? UUID()
        if ids.contains(rule.subjectID), ids.contains(target) { return true }
        guard rule.relation == .apart else { return false }
        return (ids.contains(rule.subjectID) && routine.adjacent[target] != nil)
            || (ids.contains(target) && routine.adjacent[rule.subjectID] != nil)
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

    /// Every rule the given times break. A gap rule written both ways ("X 12 h apart from Y" and
    /// "Y 12 h apart from X") is one rule, so it's reported once.
    static func violations(times: [UUID: Int], routine: EngineRoutine, rules: [ScheduleRule], names: [UUID: String]) -> [RuleViolation] {
        var reported: [ScheduleRule] = []
        return rules.compactMap { rule in
            guard let d = deficit(rule, times: times, routine: routine), d > 0 else { return nil }
            guard !reported.contains(where: { mirrors($0, rule) }) else { return nil }
            reported.append(rule)
            return explain(rule, times: times, routine: routine, names: names, deficit: d)
        }
    }

    /// "X apart from Y" and "Y apart from X" with the same gap: one instruction written both ways.
    static func mirrors(_ a: ScheduleRule, _ b: ScheduleRule) -> Bool {
        a.target == .medication && b.target == .medication && a.relation == .apart && b.relation == .apart
            && a.subjectID == b.targetMedicationID && a.targetMedicationID == b.subjectID
            && a.minMinutes == b.minMinutes && a.maxMinutes == b.maxMinutes
    }

    /// A gap rule between two medications ("10 h apart"): the doses it links.
    static func linkedPair(_ rule: ScheduleRule) -> (UUID, UUID)? {
        guard rule.target == .medication, rule.relation == .apart, let other = rule.targetMedicationID, other != rule.subjectID
        else { return nil }
        return (rule.subjectID, other)
    }

    /// How many minutes a rule is off by (0 = satisfied), or nil when it can't be checked yet.
    static func deficit(_ rule: ScheduleRule, times: [UUID: Int], routine: EngineRoutine) -> Int? {
        if rule.target == .medication, rule.relation == .apart {
            let minV = rule.minMinutes ?? 0
            return closestApartPair(rule, times: times, routine: routine).map { pair in
                let gap = abs(pair.subject - pair.other)
                if gap < minV { return minV - gap }
                if let maxV = rule.maxMinutes, maxV >= minV, gap > maxV { return gap - maxV }
                return 0
            }
        }
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

    /// For "X and Y at least N apart": the closest pair of doses where at least one is today
    /// (today–today, today–the night before, today–the next day). Nil when no such pair exists.
    static func closestApartPair(_ rule: ScheduleRule, times: [UUID: Int], routine: EngineRoutine) -> (subject: Int, other: Int)? {
        guard let id = rule.targetMedicationID, id != rule.subjectID else { return nil }
        var pairs: [(Int, Int)] = []
        let s = times[rule.subjectID]
        let o = times[id]
        if let s, let o { pairs.append((s, o)) }
        if let s { pairs += routine.neighbours(id, times: times).map { (s, $0) } }
        if let o { pairs += routine.neighbours(rule.subjectID, times: times).map { ($0, o) } }
        return pairs.min { abs($0.0 - $0.1) < abs($1.0 - $1.1) }.map { (subject: $0.0, other: $0.1) }
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
                let pair = closestApartPair(rule, times: times, routine: routine) ?? (t, other)
                let gap = abs(pair.subject - pair.other)
                if let maxV = rule.maxMinutes, maxV >= minV, gap > maxV {
                    message = "\(subject) and \(target) are now \(duration(gap)) apart; your rule is \(duration(minV))–\(duration(maxV))"
                    let goal = t >= other ? other + maxV : other - maxV
                    fix = "Closest fix: take \(subject) at \(clock(goal))."
                    break
                }
                func when(_ m: Int) -> String { m < 0 ? " the night before" : m >= 1440 ? " the next day" : "" }
                if pair.other < 0 || pair.other >= 1440 {
                    // Today's subject against the other medication on a neighbouring day.
                    let side = pair.other < 0 ? "after" : "before"
                    message = "\(subject) is now \(duration(gap)) \(side) \(target)\(when(pair.other)); your rule is \(duration(minV)) apart"
                    let goal = pair.other < 0 ? pair.other + minV : pair.other - minV
                    fix = "Closest fix: take \(subject) at \(clock(goal))."
                } else if pair.subject < 0 || pair.subject >= 1440 {
                    let side = pair.subject < 0 ? "after" : "before"
                    message = "\(target) is now \(duration(gap)) \(side) \(subject)\(when(pair.subject)); your rule is \(duration(minV)) apart"
                    let goal = pair.subject < 0 ? pair.subject + minV : pair.subject - minV
                    fix = "Closest fix: take \(target) at \(clock(goal))."
                } else {
                    message = "\(subject) and \(target) are now \(duration(gap)) apart; your rule is \(duration(minV))"
                    let goal = t >= other ? other + minV : other - minV
                    fix = "Closest fix: take \(subject) at \(clock(goal)), or change the rule to \(duration(gap))."
                }
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
            } else if rule.relation == .after, minV == 0 {
                message = "\(subject) is now at \(clock(t)), before waking up (\(clock(routine.wake)))"
                fix = "Closest fix: take \(subject) at \(clock(routine.wake))."
            } else if rule.relation == .after {
                message = "\(subject) is now \(duration(max(0, t - routine.wake))) after waking; your rule is \(duration(minV))"
            }

        case .bed:
            let goal = routine.bed - minV
            message = rule.relation == .before
                ? (minV == 0 ? "\(subject) is now at \(clock(t)), after bedtime (\(clock(routine.bed)))"
                   : "\(subject) is now \(duration(max(0, routine.bed - t))) before bed; your rule is \(duration(minV))")
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
            if let maxV = rule.maxMinutes { return "within \(duration(maxV)) \(word) \(what)" }
            return minV == 0 ? "\(word) \(what)" : "at least \(duration(minV)) \(word) \(what)"
        }
        let text: String
        switch (rule.target, rule.relation) {
        case (.medication, .after): text = gap("after", target)
        case (.medication, .before): text = gap("before", target)
        case (.medication, .apart):
            if let maxV = rule.maxMinutes, maxV > minV {
                text = "\(duration(minV))–\(duration(maxV)) apart from \(target)"
            } else {
                text = "at least \(duration(minV)) apart from \(target)"
            }
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

    // MARK: Fixing

    /// Every dose stays between waking up and bedtime. These implied rules join her own whenever a time is set,
    /// so a dose after bedtime is named and fixed like any other broken rule. Ids are stable per medication.
    static func dayBounds(for ids: some Sequence<UUID>) -> [ScheduleRule] {
        ids.sorted { $0.uuidString < $1.uuidString }.flatMap { id in
            [ScheduleRule(id: derived(id, 0xB0), subjectID: id, relation: .after, target: .wake, minMinutes: 0),
             ScheduleRule(id: derived(id, 0xBE), subjectID: id, relation: .before, target: .bed, minMinutes: 0)]
        }
    }

    private static func derived(_ id: UUID, _ salt: UInt8) -> UUID {
        var u = id.uuid
        u.0 ^= salt
        u.15 ^= salt
        return UUID(uuid: u)
    }

    /// The time nearest `target` (5-minute steps, earlier first on ties) inside `range` where every rule
    /// involving `id` holds, or nil when there is none.
    static func closestValid(for id: UUID, near target: Int, times: [UUID: Int], routine: EngineRoutine,
                             rules: [ScheduleRule], range: ClosedRange<Int>) -> Int? {
        let relevant = rules.filter { $0.involves(id) }
        let start = roundNearest(target)
        func fits(_ t: Int) -> Bool {
            var candidate = times
            candidate[id] = t
            return relevant.allSatisfy { (deficit($0, times: candidate, routine: routine) ?? 0) == 0 }
        }
        var offset = 0
        while offset <= 1440 {
            for t in offset == 0 ? [start] : [start - offset, start + offset] where range.contains(t) && fits(t) {
                return t
            }
            offset += step
        }
        return nil
    }

    /// After one item moved: the fewest moves that put things right. Each medication (in dependency order) that
    /// now breaks a rule moves to the closest time that keeps all of its rules; `locked` and pinned ones never move.
    /// Whatever still can't fit stays where it is and shows up as a violation.
    /// `linked`: when a gap rule still breaks, try moving both of its doses together (see `placePair`).
    static func settle(times: [UUID: Int], locked: Set<UUID>, meds: [EngineMed], routine: EngineRoutine,
                       rules: [ScheduleRule], range: ClosedRange<Int>, linked: Bool = true) -> [UUID: Int] {
        var result = times
        for _ in 0..<2 {
            for med in order(meds, rules: rules) where !locked.contains(med.id) && med.pinned == nil {
                guard let current = result[med.id] else { continue }
                let broken = rules.contains { $0.involves(med.id) && (deficit($0, times: result, routine: routine) ?? 0) > 0 }
                guard broken,
                      let t = closestValid(for: med.id, near: current, times: result, routine: routine, rules: rules, range: range)
                else { continue }
                result[med.id] = t
            }
        }
        guard linked else { return result }
        let movable = Set(meds.filter { $0.pinned == nil && !locked.contains($0.id) }.map(\.id))
        return placeLinked(times: result, movable: movable, routine: routine, rules: rules, range: range)
    }

    /// Every gap rule between two movable doses that still breaks: both doses move together to the closest
    /// pair that keeps every rule of both. Left as they are when no pair works.
    static func placeLinked(times: [UUID: Int], movable: Set<UUID>, routine: EngineRoutine, rules: [ScheduleRule],
                            range: ClosedRange<Int>) -> [UUID: Int] {
        var result = times
        for rule in rules {
            guard let (a, b) = linkedPair(rule), movable.contains(a), movable.contains(b),
                  result[a] != nil, result[b] != nil,
                  (deficit(rule, times: result, routine: routine) ?? 0) > 0,
                  let pair = placePair(a, b, times: result, routine: routine, rules: rules, range: range)
            else { continue }
            result[a] = pair.a
            result[b] = pair.b
        }
        return result
    }

    /// The two doses' times closest to where they are now (least total movement, 5-minute steps, inside `range`)
    /// where every rule involving either holds, or nil when there is none.
    static func placePair(_ a: UUID, _ b: UUID, times: [UUID: Int], routine: EngineRoutine, rules: [ScheduleRule],
                          range: ClosedRange<Int>) -> (a: Int, b: Int)? {
        guard let a0 = times[a], let b0 = times[b], range.lowerBound <= range.upperBound else { return nil }
        let aRules = rules.filter { $0.involves(a) }
        let candidates = stride(from: roundUp(range.lowerBound), through: range.upperBound, by: step)
            .sorted { (abs($0 - a0), $0) < (abs($1 - a0), $1) }
        var best: (cost: Int, a: Int, b: Int)?
        for ta in candidates {
            let da = abs(ta - a0)
            if let best, da >= best.cost { break }
            var trial = times
            trial[a] = ta
            guard let tb = closestValid(for: b, near: b0, times: trial, routine: routine, rules: rules, range: range) else { continue }
            trial[b] = tb
            guard aRules.allSatisfy({ (deficit($0, times: trial, routine: routine) ?? 0) == 0 }) else { continue }
            let cost = da + abs(tb - b0)
            if best == nil || cost < best!.cost { best = (cost, ta, tb) }
        }
        return best.map { (a: $0.a, b: $0.b) }
    }

    /// One-tap fixes for a broken rule: move its medication, move the other medication, or (today only) skip one.
    /// `fixed` are doses already logged; they never move or get skipped.
    static func fixes(for violation: RuleViolation, times: [UUID: Int], fixed: Set<UUID>, routine: EngineRoutine,
                      rules: [ScheduleRule], names: [UUID: String], range: ClosedRange<Int>, allowSkip: Bool,
                      pinned: Set<UUID> = []) -> [ScheduleFix] {
        let rule = violation.rule
        var result: [ScheduleFix] = []
        let subject = rule.subjectID
        let other = rule.target == .medication ? rule.targetMedicationID : nil

        if !fixed.contains(subject), let current = times[subject],
           let t = closestValid(for: subject, near: current, times: times, routine: routine, rules: rules, range: range), t != current {
            result.append(ScheduleFix(title: "Move \(names[subject] ?? "it") to \(clock(t))", kind: .move(subject, t)))
        }
        if let other, !fixed.contains(other), !pinned.contains(other), let current = times[other],
           let t = closestValid(for: other, near: current, times: times, routine: routine, rules: rules, range: range), t != current {
            let delta = t - current
            result.append(ScheduleFix(title: "Take \(names[other] ?? "it") \(duration(abs(delta))) \(delta < 0 ? "earlier" : "later")",
                                      kind: .move(other, t)))
        }
        // Neither dose can move alone, but both together can ("AM and PM 12 h apart").
        if result.isEmpty, let (a, b) = linkedPair(rule), !fixed.contains(a), !fixed.contains(b),
           !pinned.contains(a), !pinned.contains(b),
           let pair = placePair(a, b, times: times, routine: routine, rules: rules, range: range) {
            var moved = times
            moved[a] = pair.a
            moved[b] = pair.b
            result.append(ScheduleFix(title: "Move \(names[a] ?? "it") to \(clock(pair.a)) and \(names[b] ?? "it") to \(clock(pair.b))",
                                      kind: .retime(ScheduleFix.RoutineTweak(times: moved))))
        }
        if allowSkip {
            if !fixed.contains(subject) {
                result.append(ScheduleFix(title: "Skip \(names[subject] ?? "it") today", kind: .skip(subject)))
            } else if let other, !fixed.contains(other) {
                result.append(ScheduleFix(title: "Skip \(names[other] ?? "it") today", kind: .skip(other)))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.title).inserted }
    }

    /// When no dose can move to keep a rule: the smallest change to the routine that does, without breaking anything new.
    /// Tries a later bedtime, an earlier wake-up, and moving each meal, in 5-minute steps; returns at most one of each kind
    /// (up to two in all, closest first).
    static func routineFixes(for violation: RuleViolation, times: [UUID: Int], meds: [EngineMed], routine: EngineRoutine,
                             rules: [ScheduleRule], names: [UUID: String]) -> [ScheduleFix] {
        let brokenBefore = Set(violations(times: times, routine: routine, rules: rules, names: names).map(\.rule.id))
        func attempt(_ r: EngineRoutine) -> [UUID: Int]? {
            guard r.wake < r.bed else { return nil }
            let settled = settle(times: times, locked: [], meds: meds, routine: r, rules: rules, range: r.wake...r.bed, linked: false)
            let after = Set(violations(times: settled, routine: r, rules: rules, names: names).map(\.rule.id))
            guard !after.contains(violation.rule.id), after.isSubset(of: brokenBefore) else { return nil }
            return settled
        }
        var found: [(cost: Int, fix: ScheduleFix)] = []
        // A later bedtime.
        for b in stride(from: routine.bed + step, through: 23 * 60 + 55, by: step) {
            var r = routine
            r.bed = b
            if let t = attempt(r) {
                found.append((b - routine.bed, ScheduleFix(title: "Move bedtime to \(clock(b))",
                                                           kind: .retime(ScheduleFix.RoutineTweak(bed: b, times: t)))))
                break
            }
        }
        // An earlier wake-up.
        for w in stride(from: routine.wake - step, through: 4 * 60, by: -step) {
            var r = routine
            r.wake = w
            if let t = attempt(r) {
                found.append((routine.wake - w, ScheduleFix(title: "Wake up at \(clock(w))",
                                                            kind: .retime(ScheduleFix.RoutineTweak(wake: w, times: t)))))
                break
            }
        }
        // One meal earlier or later (up to 3 h), keeping meals in order and inside the day.
        var bestMeal: (cost: Int, fix: ScheduleFix)?
        for (i, meal) in routine.meals.enumerated() {
            for offset in stride(from: step, through: 180, by: step) {
                if let best = bestMeal, offset >= best.cost { break }
                var hit: (Int, [UUID: Int])?
                for start in [meal.start - offset, meal.start + offset] {
                    guard start >= routine.wake, start + meal.duration <= routine.bed else { continue }
                    var r = routine
                    r.meals[i].start = start
                    let sorted = r.meals.map(\.start)
                    guard sorted == sorted.sorted() else { continue }
                    if let t = attempt(r) { hit = (start, t); break }
                }
                if let (start, t) = hit {
                    bestMeal = (offset, ScheduleFix(title: "Move \(meal.name.lowercased()) to \(clock(start))",
                                                    kind: .retime(ScheduleFix.RoutineTweak(mealName: meal.name, mealStart: start, times: t))))
                    break
                }
            }
        }
        if let bestMeal { found.append(bestMeal) }
        return found.sorted { $0.cost < $1.cost }.prefix(2).map(\.fix)
    }

    /// Why a rule can't be kept, in one or two sentences:
    /// "Iron needs at least 4 h after Thyroid. The earliest Iron can go is 11:15 PM, after bedtime."
    static func blockedReason(for violation: RuleViolation, times: [UUID: Int], fixed: Set<UUID>, routine: EngineRoutine,
                              rules: [ScheduleRule], names: [UUID: String], range: ClosedRange<Int>) -> String {
        let rule = violation.rule
        let subjectName = names[rule.subjectID] ?? "This medication"
        let goes = rule.relation == .with || rule.relation == .at || (rule.target == .wake && rule.relation != .after)
            || (rule.target == .bed && rule.relation != .before) || rule.isDayBound
        var text = describe(rule, names: names, includeSubject: false)
        if rule.isNoFood { text += " it" }
        let head = rule.isDayBound ? violation.message.replacingOccurrences(of: " is now at ", with: " is at ") + "."
            : "\(subjectName) \(goes ? "goes" : "needs") \(text)."

        let target = rule.target == .medication ? rule.targetMedicationID : nil
        let movable: UUID? = !fixed.contains(rule.subjectID) && times[rule.subjectID] != nil
            ? rule.subjectID : target.flatMap { fixed.contains($0) || times[$0] == nil ? nil : $0 }
        guard let id = movable else { return head }
        let name = names[id] ?? "It"
        let window = stride(from: 0, through: 1435, by: step).filter { t in
            var candidate = times
            candidate[id] = t
            return (deficit(rule, times: candidate, routine: routine) ?? 0) == 0
        }
        guard let first = window.first, let last = window.last else {
            // A gap rule between two doses: try them together before saying nothing works.
            if let (a, b) = linkedPair(rule), !fixed.contains(a), !fixed.contains(b) {
                if placePair(a, b, times: times, routine: routine, rules: rules, range: range) != nil {
                    return head + " \(names[a] ?? "One dose") and \(names[b] ?? "the other") need to move together."
                }
                if placePair(a, b, times: times, routine: routine, rules: [rule], range: 0...1435) != nil {
                    return head + " Both doses would have to move, and no times between waking up and bedtime keep every rule."
                }
            }
            return head + " No time in the day works for it."
        }
        let inRange = window.filter { range.contains($0) }
        if inRange.isEmpty {
            if first > range.upperBound {
                return head + " The earliest \(name) can go is \(clock(first)), after bedtime."
            }
            if last < range.lowerBound {
                let passed = range.lowerBound > roundUp(routine.wake)
                return head + " The latest \(name) could go was \(clock(last)), \(passed ? "already passed" : "before waking up")."
            }
            return head + " No time between \(clock(range.lowerBound)) and bedtime works."
        }
        if closestValid(for: id, near: inRange[0], times: times, routine: routine, rules: rules, range: range) == nil {
            let others = rules.filter { $0.involves(id) && $0.id != rule.id }
            let clash = others.first { o in
                !inRange.contains { t in
                    var candidate = times
                    candidate[id] = t
                    return (deficit(o, times: candidate, routine: routine) ?? 0) == 0
                }
            } ?? others.first
            if let clash {
                if clash.subjectID == id, clash.target != .medication {
                    return head + " Its rule \u{201C}\(describe(clash, names: names, includeSubject: false))\u{201D} keeps it there."
                }
                return head + " That can't fit together with \(describe(clash, names: names))."
            }
        }
        return head
    }

    /// Short live text while dragging: "Iron would be 3 h after Thyroid; needs 4 h".
    static func shortReason(_ violation: RuleViolation) -> String {
        violation.message
            .replacingOccurrences(of: " is now ", with: " would be ")
            .replacingOccurrences(of: " are now ", with: " would be ")
            .replacingOccurrences(of: "; your rule is ", with: "; needs ")
            .replacingOccurrences(of: "; your rule puts it at ", with: "; goes at ")
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
