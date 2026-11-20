import Foundation

/// How the pregnancy is dated. Raw values match the backend enum.
nonisolated enum DatingMethod: String, Codable, CaseIterable, Identifiable {
    case ovulation
    case lmp
    case dueDate = "due_date"
    case ivfTransfer = "ivf_transfer"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ovulation: "Ovulation or conception"
        case .lmp: "Last period"
        case .dueDate: "Known due date"
        case .ivfTransfer: "IVF transfer"
        }
    }

    var subtitle: String {
        switch self {
        case .ovulation: "The day you ovulated or conceived. Most precise if you tracked it."
        case .lmp: "The first day of your last period."
        case .dueDate: "A due date you already have from your provider."
        case .ivfTransfer: "The day your embryo was transferred."
        }
    }

    var datePrompt: String {
        switch self {
        case .ovulation: "When did you ovulate?"
        case .lmp: "When did your last period start?"
        case .dueDate: "When is your due date?"
        case .ivfTransfer: "When was your transfer?"
        }
    }

    var symbol: String {
        switch self {
        case .ovulation: "sparkles"
        case .lmp: "drop.fill"
        case .dueDate: "calendar"
        case .ivfTransfer: "leaf.fill"
        }
    }
}

nonisolated struct PregnancyProfile: Codable, Equatable {
    var momName: String
    var partnerName: String
    var babyNickname: String
    var datingMethod: DatingMethod
    var datingDate: Date
    /// Embryo age in days at transfer (IVF only): 3 or 5.
    var embryoAgeDays: Int
    var dueDate: Date
    /// Tracking paused: pregnancy content hides on both phones; meds, reminders and history keep working.
    var trackingPaused: Bool
    var trackingPausedAt: Date?
    /// The user id of whoever paused it.
    var trackingPausedBy: String?

    private enum CodingKeys: String, CodingKey {
        case momName, partnerName, babyNickname, datingMethod, datingDate, embryoAgeDays, dueDate
        case trackingPaused, trackingPausedAt, trackingPausedBy
    }

    init(
        momName: String, partnerName: String, babyNickname: String,
        datingMethod: DatingMethod, datingDate: Date, embryoAgeDays: Int, dueDate: Date,
        trackingPaused: Bool = false, trackingPausedAt: Date? = nil, trackingPausedBy: String? = nil
    ) {
        self.momName = momName
        self.partnerName = partnerName
        self.babyNickname = babyNickname
        self.datingMethod = datingMethod
        self.datingDate = datingDate
        self.embryoAgeDays = embryoAgeDays
        self.dueDate = dueDate
        self.trackingPaused = trackingPaused
        self.trackingPausedAt = trackingPausedAt
        self.trackingPausedBy = trackingPausedBy
    }

    /// Files saved before tracking could be paused decode as not paused.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        momName = try c.decode(String.self, forKey: .momName)
        partnerName = try c.decodeIfPresent(String.self, forKey: .partnerName) ?? ""
        babyNickname = try c.decodeIfPresent(String.self, forKey: .babyNickname) ?? ""
        datingMethod = try c.decode(DatingMethod.self, forKey: .datingMethod)
        datingDate = try c.decode(Date.self, forKey: .datingDate)
        embryoAgeDays = try c.decodeIfPresent(Int.self, forKey: .embryoAgeDays) ?? 5
        dueDate = try c.decode(Date.self, forKey: .dueDate)
        trackingPaused = try c.decodeIfPresent(Bool.self, forKey: .trackingPaused) ?? false
        trackingPausedAt = try c.decodeIfPresent(Date.self, forKey: .trackingPausedAt)
        trackingPausedBy = try c.decodeIfPresent(String.self, forKey: .trackingPausedBy)
    }

    var babyName: String {
        let trimmed = babyNickname.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Baby" : trimmed
    }

    var hasPartner: Bool { !partnerName.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Ovulation (conception) date = due date - 266 days.
    var ovulationDate: Date { PregnancyMath.addDays(-PregnancyMath.ovulationToDue, to: dueDate) }

    /// Gestational age counts from ovulation date - 14 days.
    var gestationStart: Date { PregnancyMath.addDays(-14, to: ovulationDate) }

    func progress(on date: Date = .now) -> GestationalAge {
        GestationalAge(start: gestationStart, due: dueDate, today: date)
    }

    /// Switches dating method while keeping the same due date.
    mutating func switchMethod(to method: DatingMethod) {
        let ovulation = ovulationDate
        datingMethod = method
        switch method {
        case .ovulation: datingDate = ovulation
        case .lmp: datingDate = PregnancyMath.addDays(-14, to: ovulation)
        case .dueDate: datingDate = dueDate
        case .ivfTransfer: datingDate = PregnancyMath.addDays(embryoAgeDays, to: ovulation)
        }
    }

    /// Recalculates the due date from the dating method + date.
    mutating func recalculateDueDate() {
        dueDate = PregnancyMath.dueDate(method: datingMethod, date: datingDate, embryoAgeDays: embryoAgeDays)
    }
}

nonisolated enum PregnancyMath {
    static let ovulationToDue = 266
    static let fullTerm = 280

    static var calendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = .current
        return cal
    }

    static func addDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }

    static func ovulationDate(method: DatingMethod, date: Date, embryoAgeDays: Int) -> Date {
        switch method {
        case .ovulation: calendar.startOfDay(for: date)
        case .lmp: addDays(14, to: date)
        case .dueDate: addDays(-ovulationToDue, to: date)
        case .ivfTransfer: addDays(-embryoAgeDays, to: date)
        }
    }

    static func dueDate(method: DatingMethod, date: Date, embryoAgeDays: Int) -> Date {
        addDays(ovulationToDue, to: ovulationDate(method: method, date: date, embryoAgeDays: embryoAgeDays))
    }

    static func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// Allowed range for the dating date so results stay within a plausible pregnancy.
    static func allowedRange(for method: DatingMethod) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: .now)
        switch method {
        case .dueDate:
            return addDays(-21, to: today)...addDays(300, to: today)
        case .lmp:
            return addDays(-301, to: today)...today
        case .ovulation, .ivfTransfer:
            return addDays(-287, to: today)...today
        }
    }
}

nonisolated struct GestationalAge {
    let totalDays: Int
    let daysToGo: Int

    init(start: Date, due: Date, today: Date) {
        totalDays = max(0, PregnancyMath.days(from: start, to: today))
        daysToGo = PregnancyMath.days(from: today, to: due)
    }

    var weeks: Int { totalDays / 7 }
    var days: Int { totalDays % 7 }

    /// Week used for the weekly content (1...42).
    var contentWeek: Int { min(max(weeks, 1), 42) }

    var trimester: Int {
        switch weeks {
        case ..<14: 1
        case 14..<28: 2
        default: 3
        }
    }

    var trimesterTitle: String {
        switch trimester {
        case 1: "First trimester"
        case 2: "Second trimester"
        default: "Third trimester"
        }
    }

    var ringProgress: Double { Double(totalDays) / 280.0 }

    var headline: String { Self.headline(weeks: weeks, days: days) }

    static func headline(weeks: Int, days: Int) -> String {
        let w = weeks == 1 ? "1 week" : "\(weeks) weeks"
        if days == 0 { return w }
        return "\(w) + \(days) \(days == 1 ? "day" : "days")"
    }

    var daysToGoText: String {
        if daysToGo > 1 { return "\(daysToGo) days to go" }
        if daysToGo == 1 { return "1 day to go" }
        if daysToGo == 0 { return "Due today" }
        return "\(-daysToGo) \(daysToGo == -1 ? "day" : "days") past due"
    }
}
