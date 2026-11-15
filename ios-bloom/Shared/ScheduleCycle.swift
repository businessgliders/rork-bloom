import Foundation

/// The schedule as one continuous cycle across midnight. Pure and deterministic.
///
/// - A routine's own times are its typical day: gap rules ("10 h apart") are checked against the routine
///   itself on the night before and the morning after (Tuesday after Monday).
/// - Where one routine hands over to another (Sunday's Weekend → Monday's Weekdays), `handover` settles
///   that one day against the actual day before, so Monday can start later without moving every weekday.
nonisolated enum ScheduleCycle {
    /// Each medication's minutes in a routine.
    static func times(_ template: ScheduleTemplate) -> [UUID: [Int]] {
        Dictionary(grouping: template.doses, by: \.medicationID).mapValues { $0.map(\.time.minutesFromMidnight) }
    }

    /// Neighbour-day minutes for a routine (see `EngineRoutine.adjacent`). When the routine continues into
    /// itself on at least one day, only that continuation counts; otherwise (a single-day routine) the
    /// routines on either side do.
    static func adjacent(for template: ScheduleTemplate, in templates: [ScheduleTemplate]) -> [UUID: [Int]] {
        let own = templates.filter { $0.owner == template.owner && $0.id != template.id } + [template]
        func covering(_ day: Int) -> ScheduleTemplate? {
            template.days.contains(day) ? template : own.first { $0.days.contains(day) }
        }
        let continues = template.days.contains { template.days.contains(($0 + 1) % 7) }
        var previous: [UUID: [Int]] = [:]
        var next: [UUID: [Int]] = [:]
        for day in template.days {
            if let p = covering((day + 6) % 7), !continues || p.id == template.id {
                previous.merge(times(p)) { $0 + $1 }
            }
            if let n = covering((day + 1) % 7), !continues || n.id == template.id {
                next.merge(times(n)) { $0 + $1 }
            }
        }
        return EngineRoutine.adjacent(previous: previous, next: next)
    }

    /// Places every routine of the given list. Neighbours depend on each other's times, so this runs
    /// to a fixed point (at most 4 passes; one more pass than needed is cheap).
    static func generateAll(_ templates: [ScheduleTemplate], meds: (ScheduleTemplate) -> [EngineMed],
                            rules: (MedOwner) -> [ScheduleRule]) -> (templates: [ScheduleTemplate], violations: [UUID: [RuleViolation]]) {
        var current = templates
        var found: [UUID: [RuleViolation]] = [:]
        for pass in 0..<4 {
            var changed = false
            for i in current.indices {
                let template = current[i]
                let list = meds(template)
                let routine = EngineRoutine(template, adjacent: adjacent(for: template, in: current))
                let result = ScheduleEngine.generate(routine: routine, meds: list, rules: rules(template.owner))
                var t = template
                t.doses = list.compactMap { med in
                    guard let minutes = result.times[med.id] else { return nil }
                    let existing = template.dose(for: med.id)
                    return TemplateDose(id: existing?.id ?? UUID(), medicationID: med.id, time: DoseTime(minutes: minutes),
                                        pinned: med.pinned != nil)
                }
                if t.doses != template.doses { changed = true }
                current[i] = t
                found[t.id] = result.violations
            }
            if !changed && pass > 0 { break }
        }
        return (current, found)
    }

    /// One day's times checked against the day before (its actual planned or taken minutes, 0..<1440 on
    /// that day). When a gap rule breaks across midnight, the day's doses settle to the closest times that
    /// keep every rule; otherwise the times come back unchanged.
    static func handover(times: [UUID: Int], previous: [UUID: Int], wake: Int, bed: Int, meals: [EngineMeal],
                         meds: [EngineMed], rules: [ScheduleRule]) -> [UUID: Int] {
        let routine = EngineRoutine(wake: wake, bed: bed, meals: meals,
                                    adjacent: EngineRoutine.adjacent(previous: previous.mapValues { [$0] }, next: [:]))
        let ids = Set(times.keys)
        let usable = rules.filter { ScheduleEngine.applies($0, on: ids, routine: routine) } + ScheduleEngine.dayBounds(for: ids)
        let crossBroken = usable.contains { rule in
            rule.target == .medication && rule.relation == .apart
                && (ScheduleEngine.deficit(rule, times: times, routine: routine) ?? 0) > 0
        }
        guard crossBroken else { return times }
        return ScheduleEngine.settle(times: times, locked: [], meds: meds, routine: routine, rules: usable,
                                     range: wake...max(bed, wake))
    }
}
