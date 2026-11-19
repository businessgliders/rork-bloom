import Foundation
import UIKit
import UserNotifications

/// "Progesterone AM moved to 9:45 AM tomorrow, 10 h after last night's dose." Banner (and panel line) with Undo.
nonisolated struct AutoMoveNotice: Codable, Equatable, Identifiable {
    /// The move's record id.
    var id: UUID
    var owner: MedOwner
    var dayKey: String
    var message: String
    var createdAt: Date

    private static let key = "carry.autoMoveNotice.v1"

    static func loadSaved() -> AutoMoveNotice? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notice = try? JSONDecoder().decode(AutoMoveNotice.self, from: data) else { return nil }
        // Only while the moved day is today or later.
        guard let day = PlanDay.date(notice.dayKey), day >= PregnancyMath.calendar.startOfDay(for: .now) else { return nil }
        return notice
    }

    static func save(_ notice: AutoMoveNotice?) {
        if let notice, let data = try? JSONEncoder().encode(notice) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// One day this phone moved by itself. While the day's override still matches `after`, the move is
/// recomputed (or put back) whenever last night's doses change; once anyone edits that day, it is hers.
nonisolated struct AutoMoveRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var owner: MedOwner
    var dayKey: String
    /// The day's override before the move (nil: the day followed its routine).
    var before: DayOverride?
    var after: DayOverride
    /// Minutes of the doses not taken yet, before the move.
    var original: [UUID: Int]
    var moved: [UUID: Int]

    private static let key = "carry.autoMoves.v1"

    static func loadAll() -> [AutoMoveRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AutoMoveRecord].self, from: data) else { return [] }
        return list
    }

    static func saveAll(_ list: [AutoMoveRecord]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// What a late dose last night means for a day: nothing, a move, or a move that can't be made.
nonisolated enum LateDoseMove: Equatable {
    case none
    case blocked
    case moved([UUID: Int], causes: Set<UUID>)

    /// Doses on the day that break a gap rule against the day before's real doses move (only those) to the
    /// closest time keeping every rule; past bedtime, or breaking another rule, nothing moves.
    /// `previous` is the day before on this day's axis (negative minutes); `routine.adjacent` includes it.
    static func evaluate(times: [UUID: Int], fixed: Set<UUID>, pinned: Set<UUID>, previous: [UUID: [Int]],
                         meds: [EngineMed], routine: EngineRoutine, gapRules: [ScheduleRule],
                         usable: [ScheduleRule], range: ClosedRange<Int>) -> LateDoseMove {
        guard !previous.isEmpty else { return .none }
        let previousOnly = EngineRoutine(wake: routine.wake, bed: routine.bed, meals: [], adjacent: previous)
        var broken = Set<UUID>()
        var causes = Set<UUID>()
        for (id, t) in times where !fixed.contains(id) && !pinned.contains(id) {
            for rule in gapRules where rule.target == .medication && rule.relation == .apart && rule.involves(id) {
                guard let other = rule.subjectID == id ? rule.targetMedicationID : rule.subjectID, previous[other] != nil else { continue }
                if (ScheduleEngine.deficit(rule, times: [id: t], routine: previousOnly) ?? 0) > 0 {
                    broken.insert(id)
                    causes.insert(other)
                }
            }
        }
        guard !broken.isEmpty else { return .none }
        let locked = Set(times.keys).subtracting(broken)
        let settled = ScheduleEngine.settle(times: times, locked: locked, meds: meds, routine: routine, rules: usable, range: range)
        var moved: [UUID: Int] = [:]
        for id in broken {
            guard let t = settled[id], t != times[id], range.contains(t) else { return .blocked }
            moved[id] = t
        }
        // Every rule touching a moved dose holds (bedtime included), or nothing moves.
        let holds = usable.filter { rule in moved.keys.contains(where: rule.involves) }
            .allSatisfy { (ScheduleEngine.deficit($0, times: settled, routine: routine) ?? 0) == 0 }
        return holds ? .moved(moved, causes: causes) : .blocked
    }
}

extension AppStore {
    /// A late dose broke a gap rule across midnight ("10 h apart"): the next day's affected doses move to the
    /// closest time that keeps every rule, on that day only (a synced day override; routines stay the same).
    /// Checks today and tomorrow. When moving would break another rule or pass bedtime nothing moves and the
    /// row shows its usual warning. Returns true when an override changed (the caller saves).
    @discardableResult
    func autoMoveLateDoses() -> Bool {
        guard !isAutoMoving, onboardingComplete else { return false }
        isAutoMoving = true
        defer { isAutoMoving = false }
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: .now)
        let saved = AutoMoveRecord.loadAll()
        var records = saved.filter { (PlanDay.date($0.dayKey) ?? .distantPast) >= today }
        var changed = false
        var fresh: [(AutoMoveRecord, isTomorrow: Bool, causes: Set<UUID>)] = []

        for owner in Set(medications.filter(\.managed).map(\.owner)) {
            for offset in 0...1 {
                guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
                let key = PlanDay.key(day)
                let existing = override(for: owner, on: day)
                var ours: AutoMoveRecord?
                if let i = records.firstIndex(where: { $0.owner == owner && $0.dayKey == key }) {
                    if let existing, existing.times == records[i].after.times {
                        ours = records[i]
                    } else {
                        // She, or the other phone, changed this day since: it's theirs now.
                        records.remove(at: i)
                    }
                }
                // A day someone set by hand is never moved by itself.
                if existing != nil, ours == nil { continue }
                guard var s = dayState(owner, on: day) else { continue }
                if let ours {
                    for (id, m) in ours.original where s.times[id] != nil && !s.fixed.contains(id) { s.times[id] = m }
                }
                switch lateDoseMove(owner, day: day, state: s) {
                case .none, .blocked:
                    // Nothing to move any more (the late dose was undone or corrected), or it can't move: put it back.
                    if let ours {
                        restore(ours, keepOriginal: false)
                        records.removeAll { $0.id == ours.id }
                        if autoMoveNotice?.id == ours.id { autoMoveNotice = nil }
                        changed = true
                    }
                case .moved(let moved, let causes):
                    if let ours, ours.moved == moved { continue }
                    var times = s.times
                    for (id, m) in moved { times[id] = m }
                    let change = ScheduleChange(
                        kind: .logged, placement: .top, owner: owner, date: day, templateID: s.template.id,
                        routineName: s.template.displayName, subjectID: nil, subjectName: "", wake: s.wake, bed: s.bed,
                        meals: s.meals, times: times, original: s.times, fixed: s.fixed, pinned: s.pinned, range: s.range,
                        adjacent: s.adjacent, isNextDay: offset == 1
                    )
                    writeDayOverride(change, meals: nil, wake: nil, bed: nil)
                    guard let after = override(for: owner, on: day) else { continue }
                    var original: [UUID: Int] = [:]
                    for (id, m) in s.times where !s.fixed.contains(id) { original[id] = m }
                    let record = AutoMoveRecord(id: ours?.id ?? UUID(), owner: owner, dayKey: key, before: ours?.before ?? existing,
                                                after: after, original: original, moved: moved)
                    records.removeAll { $0.owner == owner && $0.dayKey == key }
                    records.append(record)
                    fresh.append((record, offset == 1, causes))
                    changed = true
                }
            }
        }
        if records != saved { AutoMoveRecord.saveAll(records) }
        guard changed else { return false }
        rebuildPlan()
        for (record, isTomorrow, causes) in fresh { announce(record, isTomorrow: isTomorrow, causes: causes) }
        return true
    }

    /// Which doses on `day` break a gap rule against the day before's real doses, and where they can go.
    private func lateDoseMove(_ owner: MedOwner, day: Date, state s: DayState) -> LateDoseMove {
        LateDoseMove.evaluate(times: s.times, fixed: s.fixed, pinned: s.pinned, previous: previousDayDoses(owner, before: day),
                              meds: s.meds, routine: s.routine, gapRules: rules(for: owner),
                              usable: usableRules(owner, times: s.times, adjacent: s.adjacent), range: s.range)
    }

    /// Puts a moved day back. Undo keeps the original times as that day's own plan, so neither phone moves it again.
    private func restore(_ record: AutoMoveRecord, keepOriginal: Bool) {
        overrides.removeAll { $0.owner == record.owner && PlanDay.key($0.date) == record.dayKey }
        if let before = record.before {
            overrides.append(before)
        } else if keepOriginal {
            var o = record.after
            for (id, m) in record.original where o.times[id] != nil { o.times[id] = DoseTime(minutes: m) }
            overrides.append(o)
        }
        enqueue(.plan, record.owner.rawValue)
    }

    /// "Undo" on the banner or the panel line.
    func undoAutoMove(_ id: UUID) {
        var records = AutoMoveRecord.loadAll()
        guard let record = records.first(where: { $0.id == id }) else {
            if autoMoveNotice?.id == id { autoMoveNotice = nil }
            return
        }
        restore(record, keepOriginal: true)
        records.removeAll { $0.id == id }
        AutoMoveRecord.saveAll(records)
        if autoMoveNotice?.id == id { autoMoveNotice = nil }
        if scheduleChange?.followOn?.id == id { scheduleChange?.followOn = nil }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [MedNotifications.doseMovedID(id)])
        rebuildPlan()
        saveAndReschedule()
        Haptics.select()
    }

    func dismissAutoMoveNotice() {
        autoMoveNotice = nil
    }

    /// The phone of the person who takes it (or who logged last night's dose) says what moved.
    private func announce(_ record: AutoMoveRecord, isTomorrow: Bool, causes: Set<UUID>) {
        guard let day = PlanDay.date(record.dayKey) else { return }
        var mine = !isShared || record.owner == viewerRole
        if !mine, let yesterday = PregnancyMath.calendar.date(byAdding: .day, value: -1, to: day) {
            mine = instances(on: yesterday).contains { causes.contains($0.medication.id) && $0.log?.loggedBy == myUserID && myUserID != nil }
        }
        guard mine else { return }
        let message = moveMessage(record, day: day, isTomorrow: isTomorrow)
        autoMoveNotice = AutoMoveNotice(id: record.id, owner: record.owner, dayKey: record.dayKey, message: message, createdAt: .now)
        if UIApplication.shared.applicationState != .active {
            MedNotifications.postDoseMoved(id: record.id, title: isTomorrow ? "Tomorrow's dose moved" : "Today's dose moved", body: message)
        }
    }

    /// "Progesterone AM moved to 9:45 AM tomorrow, 10 h after last night's dose."
    private func moveMessage(_ record: AutoMoveRecord, day: Date, isTomorrow: Bool) -> String {
        let names = medicationNames
        let when = isTomorrow ? "tomorrow" : "today"
        let sorted = record.moved.sorted { $0.value < $1.value }
        if sorted.count == 1, let (id, t) = sorted.first {
            let previous = previousDayDoses(record.owner, before: day)
            let gaps = rules(for: record.owner)
                .filter { $0.target == .medication && $0.relation == .apart && $0.involves(id) }
                .compactMap { rule -> Int? in
                    guard let other = rule.subjectID == id ? rule.targetMedicationID : rule.subjectID else { return nil }
                    return previous[other]?.map { t - $0 }.filter { $0 > 0 }.min()
                }
            let name = names[id] ?? "Medication"
            if let gap = gaps.min() {
                return "\(name) moved to \(ScheduleEngine.clock(t)) \(when), \(ScheduleEngine.duration(gap)) after last night's dose."
            }
            return "\(name) moved to \(ScheduleEngine.clock(t)) \(when), after last night's late dose."
        }
        let parts = sorted.enumerated().map { i, item in
            "\(names[item.key] ?? "Medication") \(i == 0 ? "moved " : "")to \(ScheduleEngine.clock(item.value))"
        }
        return "\(parts.joined(separator: " and ")) \(when), after last night's late dose."
    }

    /// Rules saved before \"at least\" was the rule: \"10 hours apart\" stored as exactly 10 h. A single number is a minimum.
    @discardableResult
    func normalizeGapRules() -> Bool {
        var changed = false
        for i in rules.indices where rules[i].target == .medication && rules[i].relation == .apart {
            guard let lo = rules[i].minMinutes, let hi = rules[i].maxMinutes, lo == hi, lo > 0,
                  !LineParseService.statesLimit(rules[i].sourceText) else { continue }
            rules[i].maxMinutes = nil
            // An unsent local change goes up corrected (the flush reads the rule as it is now); otherwise the
            // server's copy is already right and the next pull confirms it.
            changed = true
        }
        return changed
    }
}
