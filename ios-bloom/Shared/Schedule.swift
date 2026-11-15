import Foundation

// MARK: - Rules

/// How a rule's subject relates to its target. Raw values match `schedule_rules.relation`.
nonisolated enum RuleRelation: String, Codable, CaseIterable {
    case before, after, apart, with, at
}

/// What a rule points at. Raw values match `schedule_rules.target_type`.
nonisolated enum RuleTarget: String, Codable, CaseIterable {
    case medication, food, meal, wake, bed
}

/// One timing rule read from the user's own words (never invented).
///
/// Meaning by combination:
/// - `before food, min X`: no food for X minutes after the dose.
/// - `after food, min X`: no food for X minutes before the dose.
/// - `after/before medication, min/max`: gap from the target dose. `apart medication, min`: either order.
/// - `with meal` (named) / `with food` (any meal): during the meal.
/// - `at wake/bed/meal, min`: exactly that offset (wake + min, bed − min, meal start + min).
/// - `before bed, min`; `after wake, min/max`; `before meal` counts to the meal's start, `after meal` from its end.
nonisolated struct ScheduleRule: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var owner: MedOwner = .mom
    var takerID: UUID?
    var subjectID: UUID
    var relation: RuleRelation
    var target: RuleTarget
    var targetMedicationID: UUID?
    var targetMeal: String?
    var minMinutes: Int?
    var maxMinutes: Int?
    var sourceText: String = ""
    var confirmed: Bool = false

    init(id: UUID = UUID(), owner: MedOwner = .mom, takerID: UUID? = nil, subjectID: UUID, relation: RuleRelation, target: RuleTarget,
         targetMedicationID: UUID? = nil, targetMeal: String? = nil, minMinutes: Int? = nil, maxMinutes: Int? = nil,
         sourceText: String = "", confirmed: Bool = false) {
        self.id = id
        self.owner = owner
        self.takerID = takerID
        self.subjectID = subjectID
        self.relation = relation
        self.target = target
        self.targetMedicationID = targetMedicationID
        self.targetMeal = targetMeal
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
        self.sourceText = sourceText
        self.confirmed = confirmed
    }

    /// True for "no food" rules, which create food windows on Today.
    var isNoFood: Bool { target == .food && (relation == .before || relation == .after || relation == .apart) }
    /// "After waking up" / "before bed" with no gap: the day's bounds rather than her own rule.
    var isDayBound: Bool {
        (minMinutes ?? 0) == 0 && maxMinutes == nil
            && ((target == .bed && relation == .before) || (target == .wake && relation == .after))
    }

    func involves(_ medicationID: UUID) -> Bool { subjectID == medicationID || targetMedicationID == medicationID }
}

// MARK: - Templates

/// A meal in a routine. `time` is when it starts.
nonisolated struct ScheduleMeal: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var time: DoseTime
    var durationMinutes: Int = 30
}

/// Where one medication sits in a template.
nonisolated struct TemplateDose: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var medicationID: UUID
    var time: DoseTime
    /// A clock time the user stated ("at 9 PM"); the engine never moves it.
    var pinned: Bool = false
}

/// A routine for a set of weekdays (0 = Sunday … 6 = Saturday), with the medication times placed in it.
nonisolated struct ScheduleTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var owner: MedOwner = .mom
    var takerID: UUID?
    var name: String
    var days: Set<Int> = Set(0...6)
    var wake: DoseTime
    var bed: DoseTime
    var meals: [ScheduleMeal] = []
    var doses: [TemplateDose] = []
    var updatedAt: Date = .now

    func covers(_ day: Date) -> Bool {
        days.contains(ScheduleTemplate.weekdayIndex(of: day))
    }

    func dose(for medicationID: UUID) -> TemplateDose? { doses.first { $0.medicationID == medicationID } }

    /// 0 = Sunday … 6 = Saturday (the backend's numbering).
    static func weekdayIndex(of day: Date) -> Int {
        PregnancyMath.calendar.component(.weekday, from: day) - 1
    }

    /// Weekdays in the user's locale order, as 0–6 indexes.
    static var orderedDays: [Int] { MedSchedule.weekdayOrder.map { $0 - 1 } }

    /// "Mon–Thu", "Fri–Sun", "Every day", "Mon, Wed".
    static func daysLabel(_ days: Set<Int>) -> String {
        if days.count == 7 { return "Every day" }
        if days.isEmpty { return "No days" }
        let symbols = PregnancyMath.calendar.shortWeekdaySymbols
        let order = orderedDays
        let positions = order.enumerated().filter { days.contains($0.element) }.map(\.offset)
        let contiguous = positions.count >= 3 && positions.last! - positions.first! == positions.count - 1
        if contiguous, let first = positions.first, let last = positions.last {
            return "\(symbols[order[first]])–\(symbols[order[last]])"
        }
        return positions.map { symbols[order[$0]] }.joined(separator: ", ")
    }

    /// "Weekdays", "Weekend", "Every day", otherwise the days ("Mon, Wed").
    static func autoName(_ days: Set<Int>) -> String {
        if days.isEmpty { return "New routine" }
        if days == Set(1...5) { return "Weekdays" }
        if days == [0, 6] { return "Weekend" }
        return daysLabel(days)
    }

    /// The name she gave it, or one made from its days.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Older routines were named after their days ("Mon–Fri"); those follow the days.
        return trimmed.isEmpty || trimmed == ScheduleTemplate.daysLabel(days) ? ScheduleTemplate.autoName(days) : trimmed
    }
}

/// "Just today" times for one person on one date. Replaces the template's times for that day.
nonisolated struct DayOverride: Codable, Identifiable, Equatable {
    var id = UUID()
    var owner: MedOwner = .mom
    var takerID: UUID?
    var date: Date
    var times: [UUID: DoseTime]
    var templateID: UUID?
    /// This day's own meals, wake and bed ("Just today" routine edits). Synced via `day_routines`.
    var meals: [ScheduleMeal]?
    var wake: DoseTime?
    var bed: DoseTime?
}

nonisolated enum PlanDay {
    /// "2026-11-15" key for a local day.
    static func key(_ date: Date) -> String {
        let c = PregnancyMath.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return PregnancyMath.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
