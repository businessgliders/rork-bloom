import Foundation

/// How a medication relates to food. Raw values match the backend enum.
nonisolated enum FoodRule: String, Codable, CaseIterable, Identifiable {
    case any
    case emptyStomach = "empty_stomach"
    case withFood = "with_food"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any time"
        case .emptyStomach: "Empty stomach"
        case .withFood: "With food"
        }
    }

    var symbol: String {
        switch self {
        case .any: "clock"
        case .emptyStomach: "fork.knife"
        case .withFood: "takeoutbag.and.cup.and.straw.fill"
        }
    }
}

/// Part of the day a dose belongs to. Drives timeline sections and celebrations.
nonisolated enum DaySlot: String, Codable, CaseIterable, Identifiable, Comparable {
    case morning, afternoon, evening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    /// Default time offered when the slot is switched on.
    var defaultTime: DoseTime {
        switch self {
        case .morning: DoseTime(hour: 8, minute: 0)
        case .afternoon: DoseTime(hour: 13, minute: 0)
        case .evening: DoseTime(hour: 20, minute: 0)
        }
    }

    static func slot(forHour hour: Int) -> DaySlot {
        switch hour {
        case ..<12: .morning
        case 12..<17: .afternoon
        default: .evening
        }
    }

    private var order: Int { DaySlot.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: DaySlot, rhs: DaySlot) -> Bool { lhs.order < rhs.order }
}

/// A wall-clock time of day for a scheduled dose.
nonisolated struct DoseTime: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    var slot: DaySlot { DaySlot.slot(forHour: hour) }
    var minutesFromMidnight: Int { hour * 60 + minute }

    func date(on day: Date) -> Date {
        let cal = PregnancyMath.calendar
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.startOfDay(for: day)) ?? day
    }

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(date: Date) {
        let comps = PregnancyMath.calendar.dateComponents([.hour, .minute], from: date)
        hour = comps.hour ?? 8
        minute = comps.minute ?? 0
    }

    static func < (lhs: DoseTime, rhs: DoseTime) -> Bool { lhs.minutesFromMidnight < rhs.minutesFromMidnight }
}

nonisolated enum MedSchedule: Codable, Hashable {
    case daily
    /// Weekday numbers as in `Calendar` (1 = Sunday … 7 = Saturday).
    case weekdays(Set<Int>)

    func includes(_ day: Date) -> Bool {
        switch self {
        case .daily: return true
        case .weekdays(let days):
            return days.contains(PregnancyMath.calendar.component(.weekday, from: day))
        }
    }

    var summary: String {
        switch self {
        case .daily: return "Every day"
        case .weekdays(let days):
            if days.count == 7 { return "Every day" }
            let symbols = PregnancyMath.calendar.shortWeekdaySymbols
            let ordered = MedSchedule.weekdayOrder.filter { days.contains($0) }
            return ordered.map { symbols[$0 - 1] }.joined(separator: ", ")
        }
    }

    /// Weekdays in the user's locale order (Monday-first in most regions).
    static var weekdayOrder: [Int] {
        let first = PregnancyMath.calendar.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }
}

/// Who the medication is for. Raw values match the backend member roles.
nonisolated enum MedOwner: String, Codable, CaseIterable, Identifiable {
    case mom, partner
    var id: String { rawValue }
    var other: MedOwner { self == .mom ? .partner : .mom }
    var title: String { self == .mom ? "Mom" : "Partner" }
}

nonisolated struct Medication: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The full medication name as written on the label (shown in details).
    var name: String
    /// Short name shown everywhere else (e.g. "Iron"). Empty = use `name`. Stage 4: `medications.friendly_name`.
    var friendlyName: String = ""
    var owner: MedOwner = .mom
    /// Local photo of the pill or box. Stage 4: uploaded to `medication-photos/{pregnancy_id}/`, path in `medications.photo_path`.
    var photoFilename: String?
    /// Free text the user copies from their prescription (e.g. "1 tablet, 75 mcg"). Bloom never suggests this.
    var dose: String
    var emoji: String = "💊"
    var schedule: MedSchedule = .daily
    var times: [DoseTime] = [DaySlot.morning.defaultTime]
    var foodRule: FoodRule = .any
    /// Minutes without food before the dose (empty-stomach meds).
    var noFoodBeforeMinutes: Int = 0
    /// Minutes without food after the dose (empty-stomach meds), counted from when it was actually taken.
    var noFoodAfterMinutes: Int = 0
    var notes: String = ""
    var startDate: Date = PregnancyMath.calendar.startOfDay(for: .now)
    /// Set when the user stops taking it. History before this day is kept.
    var endDate: Date?
    var createdAt: Date = .now
    /// Shared pregnancy: the member who takes it (`medications.taken_by`). `owner` mirrors that member's role.
    var takerID: UUID?
    /// Kept from the backend so a round trip doesn't lose them.
    var rulesConfirmed: Bool = true
    var purpose: String = ""
    /// Path of the uploaded photo in `medication-photos` (`{pregnancy_id}/{photoFilename}`).
    var photoPath: String?
    /// Round 1: times come from the person's schedule templates, not `times`.
    var managed: Bool = false
    /// Managed meds: the planned time for each local day (`PlanDay.key`), written by the store
    /// from templates and "Just today" overrides, so widgets and intents read the same plan.
    var plan: [String: DoseTime] = [:]
    /// Where the medication is first named in her "Your meds & rules" text (0 = first). Doses at the same
    /// minute follow this order everywhere: the list, Right now, widgets and the Live Activity.
    var textOrder: Int?
    /// Paused from its sheet: stopped like any other, but kept paused when her text is applied again.
    var paused: Bool = false

    /// The times this medication is planned for on a day.
    func plannedTimes(on day: Date) -> [DoseTime] {
        guard managed else { return times.sorted() }
        return plan[PlanDay.key(day)].map { [$0] } ?? []
    }

    /// The name shown across the app, widgets, notifications and Reminders.
    var shortName: String {
        let friendly = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return friendly.isEmpty ? name : friendly
    }

    /// Used in food-window reasons; partner meds say whose they are in a solo setup,
    /// where both people's meds share one view. A shared pregnancy shows each
    /// person's meds separately (and names them per phone), so no suffix there.
    var reasonLabel: String {
        owner == .partner && takerID == nil ? "\(shortName) (partner)" : shortName
    }

    /// "1 tablet · for Leo" style secondary line, or nil when there's nothing to add.
    func detailLine(partnerName: String?) -> String? {
        var parts: [String] = []
        let trimmedDose = dose.trimmingCharacters(in: .whitespaces)
        if !trimmedDose.isEmpty { parts.append(trimmedDose) }
        if owner == .partner {
            let partner = partnerName?.trimmingCharacters(in: .whitespaces) ?? ""
            parts.append(partner.isEmpty ? "for partner" : "for \(partner)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var hasNoFoodWindow: Bool {
        foodRule == .emptyStomach && (noFoodBeforeMinutes > 0 || noFoodAfterMinutes > 0)
    }

    var displayTitle: String {
        dose.trimmingCharacters(in: .whitespaces).isEmpty ? shortName : "\(shortName) · \(dose)"
    }

    /// Short line describing the food rule, e.g. "No food 30 min before, 30 min after".
    var foodSummary: String {
        switch foodRule {
        case .any: return "Any time, with or without food"
        case .withFood: return "Take with food"
        case .emptyStomach:
            var parts: [String] = []
            if noFoodBeforeMinutes > 0 { parts.append("\(Self.durationText(noFoodBeforeMinutes)) before") }
            if noFoodAfterMinutes > 0 { parts.append("\(Self.durationText(noFoodAfterMinutes)) after") }
            return parts.isEmpty ? "Empty stomach" : "No food " + parts.joined(separator: ", ")
        }
    }

    func isActive(on day: Date) -> Bool {
        let cal = PregnancyMath.calendar
        let d = cal.startOfDay(for: day)
        if d < cal.startOfDay(for: startDate) { return false }
        if let endDate, d > cal.startOfDay(for: endDate) { return false }
        return schedule.includes(d)
    }

    static func durationText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static let emojiChoices = ["💊", "🌿", "🍊", "🫐", "💧", "🌸", "☀️", "🌙", "🩷", "🧡"]

    init(
        id: UUID = UUID(), name: String, friendlyName: String = "", owner: MedOwner = .mom, photoFilename: String? = nil,
        dose: String, emoji: String = "💊", schedule: MedSchedule = .daily, times: [DoseTime] = [DaySlot.morning.defaultTime],
        foodRule: FoodRule = .any, noFoodBeforeMinutes: Int = 0, noFoodAfterMinutes: Int = 0, notes: String = "",
        startDate: Date = PregnancyMath.calendar.startOfDay(for: .now), endDate: Date? = nil, createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.friendlyName = friendlyName
        self.owner = owner
        self.photoFilename = photoFilename
        self.dose = dose
        self.emoji = emoji
        self.schedule = schedule
        self.times = times
        self.foodRule = foodRule
        self.noFoodBeforeMinutes = noFoodBeforeMinutes
        self.noFoodAfterMinutes = noFoodAfterMinutes
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = createdAt
    }

    /// Tolerant decoding: files saved before friendly names, owners and photos still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName) ?? ""
        owner = (try? c.decodeIfPresent(MedOwner.self, forKey: .owner)) ?? .mom
        photoFilename = try c.decodeIfPresent(String.self, forKey: .photoFilename)
        dose = try c.decodeIfPresent(String.self, forKey: .dose) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "💊"
        schedule = try c.decodeIfPresent(MedSchedule.self, forKey: .schedule) ?? .daily
        times = try c.decodeIfPresent([DoseTime].self, forKey: .times) ?? [DaySlot.morning.defaultTime]
        foodRule = (try? c.decodeIfPresent(FoodRule.self, forKey: .foodRule)) ?? .any
        noFoodBeforeMinutes = try c.decodeIfPresent(Int.self, forKey: .noFoodBeforeMinutes) ?? 0
        noFoodAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .noFoodAfterMinutes) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate) ?? PregnancyMath.calendar.startOfDay(for: .now)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        takerID = try c.decodeIfPresent(UUID.self, forKey: .takerID)
        rulesConfirmed = try c.decodeIfPresent(Bool.self, forKey: .rulesConfirmed) ?? true
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed) ?? false
        plan = (try? c.decodeIfPresent([String: DoseTime].self, forKey: .plan)) ?? [:]
        textOrder = try c.decodeIfPresent(Int.self, forKey: .textOrder)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    /// Same-time order: her text's order first, then the order they were added.
    static func sameTimeOrder(_ a: Medication, _ b: Medication) -> Bool {
        let ta = a.textOrder ?? Int.max
        let tb = b.textOrder ?? Int.max
        if ta != tb { return ta < tb }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.shortName < b.shortName
    }
}

nonisolated enum DoseStatus: String, Codable {
    case taken
    case skipped
}

/// One logged dose. `scheduledAt` identifies the planned dose; `takenAt` is when it was actually taken.
nonisolated struct DoseLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var medicationID: UUID
    var scheduledAt: Date
    var status: DoseStatus
    var takenAt: Date?
    var loggedAt: Date = .now
    /// Shared pregnancy: who logged it (`dose_logs.logged_by`), which may differ from who takes the medication.
    var loggedBy: UUID?
}

/// A planned dose on a given day, joined with its log (if any).
nonisolated struct DoseInstance: Identifiable, Equatable {
    let medication: Medication
    let scheduledAt: Date
    let log: DoseLog?

    var id: String { "\(medication.id.uuidString)-\(Int(scheduledAt.timeIntervalSince1970))" }
    var status: DoseStatus? { log?.status }
    var isTaken: Bool { log?.status == .taken }
    var isSkipped: Bool { log?.status == .skipped }
    var isPending: Bool { log == nil }
    var slot: DaySlot { DaySlot.slot(forHour: PregnancyMath.calendar.component(.hour, from: scheduledAt)) }

    /// The moment food windows count from: the actual taken time when logged, otherwise the plan.
    var anchor: Date { log?.takenAt ?? scheduledAt }

    /// Minutes between plan and actual (positive = late).
    var minutesLate: Int? {
        guard let takenAt = log?.takenAt else { return nil }
        return Int((takenAt.timeIntervalSince(scheduledAt) / 60).rounded())
    }
}
