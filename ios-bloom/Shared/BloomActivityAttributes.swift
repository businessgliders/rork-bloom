import Foundation
import ActivityKit

/// The meds Live Activity: shows the dose that needs attention and any active no-food window.
nonisolated struct BloomActivityAttributes: ActivityAttributes {
    /// Dates are Unix seconds in JSON so a server push can build the same payload.
    nonisolated struct DoseRef: Codable, Hashable {
        var medID: String
        var scheduledAt: Date
        var name: String
        var emoji: String
        var detail: String
        /// True when the dose time has passed (it's due). False = upcoming.
        var isDue: Bool

        init(medID: String, scheduledAt: Date, name: String, emoji: String, detail: String, isDue: Bool) {
            self.medID = medID
            self.scheduledAt = scheduledAt
            self.name = name
            self.emoji = emoji
            self.detail = detail
            self.isDue = isDue
        }

        private enum CodingKeys: String, CodingKey { case medID, scheduledAt, name, emoji, detail, isDue }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            medID = try c.decode(String.self, forKey: .medID)
            scheduledAt = try c.decodeUnixDate(forKey: .scheduledAt) ?? .now
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "💊"
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            isDue = try c.decodeIfPresent(Bool.self, forKey: .isDue) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(medID, forKey: .medID)
            try c.encode(scheduledAt.timeIntervalSince1970, forKey: .scheduledAt)
            try c.encode(name, forKey: .name)
            try c.encode(emoji, forKey: .emoji)
            try c.encode(detail, forKey: .detail)
            try c.encode(isDue, forKey: .isDue)
        }
    }

    /// The next uneaten meal: due, or starting within 60 min. Never sent while a no-food window runs.
    /// Dates are Unix seconds, like `DoseRef.scheduledAt`.
    nonisolated struct MealRef: Codable, Hashable {
        /// "breakfast", "lunch", "dinner" or "snack".
        var key: String
        /// The routine meal's name ("Lunch").
        var name: String
        var startAt: Date
        var endAt: Date
        /// True once the meal's start has passed.
        var isDue: Bool

        init(key: String, name: String, startAt: Date, endAt: Date, isDue: Bool) {
            self.key = key
            self.name = name
            self.startAt = startAt
            self.endAt = endAt
            self.isDue = isDue
        }

        private enum CodingKeys: String, CodingKey { case key, name, startAt, endAt, isDue }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? "snack"
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? key.capitalized
            startAt = try c.decodeUnixDate(forKey: .startAt) ?? .now
            endAt = try c.decodeUnixDate(forKey: .endAt) ?? startAt.addingTimeInterval(30 * 60)
            isDue = try c.decodeIfPresent(Bool.self, forKey: .isDue) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(name, forKey: .name)
            try c.encode(startAt.timeIntervalSince1970, forKey: .startAt)
            try c.encode(endAt.timeIntervalSince1970, forKey: .endAt)
            try c.encode(isDue, forKey: .isDue)
        }

        /// "Lunch", from the name or, failing that, the key.
        var title: String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? key.capitalized : trimmed
        }
    }

    /// What becomes true at `staleDate`, so the view stays correct even before the app updates it.
    nonisolated enum StaleReason: String, Codable, Hashable {
        case windowEnds
        case doseDue
        case mealDue
        case none
    }

    nonisolated struct ContentState: Codable, Hashable {
        var dose: DoseRef?
        /// Other doses also due right now.
        var otherDueCount: Int
        /// A confirmed no-food window that is running (counts from the real taken time).
        var windowStart: Date?
        var windowEnd: Date?
        var windowReason: String?
        var resolved: Int
        var total: Int
        var staleReason: StaleReason
        /// Optional so payloads from before meals still decode.
        var meal: MealRef?

        var hasWindow: Bool { windowStart != nil && windowEnd != nil }

        init(dose: DoseRef?, otherDueCount: Int, windowStart: Date?, windowEnd: Date?, windowReason: String?,
             resolved: Int, total: Int, staleReason: StaleReason, meal: MealRef? = nil) {
            self.meal = meal
            self.dose = dose
            self.otherDueCount = otherDueCount
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.windowReason = windowReason
            self.resolved = resolved
            self.total = total
            self.staleReason = staleReason
        }

        private enum CodingKeys: String, CodingKey {
            case dose, otherDueCount, windowStart, windowEnd, windowReason, resolved, total, staleReason, meal
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dose = try c.decodeIfPresent(DoseRef.self, forKey: .dose)
            otherDueCount = try c.decodeIfPresent(Int.self, forKey: .otherDueCount) ?? 0
            windowStart = try c.decodeUnixDate(forKey: .windowStart)
            windowEnd = try c.decodeUnixDate(forKey: .windowEnd)
            windowReason = try c.decodeIfPresent(String.self, forKey: .windowReason)
            resolved = try c.decodeIfPresent(Int.self, forKey: .resolved) ?? 0
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
            staleReason = (try? c.decodeIfPresent(StaleReason.self, forKey: .staleReason)) ?? StaleReason.none
            meal = try? c.decodeIfPresent(MealRef.self, forKey: .meal)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(dose, forKey: .dose)
            try c.encode(otherDueCount, forKey: .otherDueCount)
            try c.encodeIfPresent(windowStart?.timeIntervalSince1970, forKey: .windowStart)
            try c.encodeIfPresent(windowEnd?.timeIntervalSince1970, forKey: .windowEnd)
            try c.encodeIfPresent(windowReason, forKey: .windowReason)
            try c.encode(resolved, forKey: .resolved)
            try c.encode(total, forKey: .total)
            try c.encode(staleReason, forKey: .staleReason)
            try c.encodeIfPresent(meal, forKey: .meal)
        }
    }

    var momName: String
    /// The member whose meds this activity shows (`"local"` when not shared).
    var takerID: String
    var takerName: String
    /// "mom" or "partner".
    var takerRole: String

    init(momName: String, takerID: String, takerName: String, takerRole: String) {
        self.momName = momName
        self.takerID = takerID
        self.takerName = takerName
        self.takerRole = takerRole
    }

    private enum CodingKeys: String, CodingKey { case momName, takerID, takerName, takerRole }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        momName = try c.decodeIfPresent(String.self, forKey: .momName) ?? ""
        takerID = try c.decodeIfPresent(String.self, forKey: .takerID) ?? "local"
        takerName = try c.decodeIfPresent(String.self, forKey: .takerName) ?? momName
        takerRole = try c.decodeIfPresent(String.self, forKey: .takerRole) ?? "mom"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(momName, forKey: .momName)
        try c.encode(takerID, forKey: .takerID)
        try c.encode(takerName, forKey: .takerName)
        try c.encode(takerRole, forKey: .takerRole)
    }

    /// True when the person looking at this phone is not the one taking these meds.
    func isForSomeoneElse(viewerID: String?) -> Bool {
        guard takerID != "local", let viewerID else { return false }
        return takerID.lowercased() != viewerID.lowercased()
    }
}

nonisolated extension KeyedDecodingContainer {
    /// Accepts Unix seconds (pushes and new encodings) or ISO 8601 strings.
    func decodeUnixDate(forKey key: Key) throws -> Date? {
        if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}

nonisolated enum LiveActivityContent {
    /// How long before a dose or meal the Live Activity may appear.
    static let upcomingLead: TimeInterval = 60 * 60
    /// How long an uneaten meal stays on the card after its planned end.
    static let mealGrace: TimeInterval = 60 * 60

    /// One of today's routine meals not logged yet.
    struct MealSlot: Hashable {
        var kind: MealKind
        var name: String
        var start: Date
        var end: Date
    }

    /// The meal the card shows: the latest one already started (until a later one starts or it's
    /// an hour past its end), else the first starting within the hour. None while food has to wait.
    static func pickMeal(_ meals: [MealSlot], now: Date) -> BloomActivityAttributes.MealRef? {
        let open = meals.filter { now < $0.end.addingTimeInterval(mealGrace) }.sorted { $0.start < $1.start }
        let slot = open.last(where: { $0.start <= now })
            ?? open.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= upcomingLead })
        return slot.map {
            .init(key: $0.kind.rawValue, name: $0.name, startAt: $0.start, endAt: $0.end, isDue: $0.start <= now)
        }
    }

    /// Builds the content for `now`, or nil when nothing needs a Live Activity
    /// (no dose or meal due or coming up within the hour, and no confirmed window running).
    /// `meals` are today's uneaten routine meals for this person.
    static func make(instances: [DoseInstance], now: Date, carryOver: [DoseInstance] = [],
                     meals: [MealSlot] = []) -> (state: BloomActivityAttributes.ContentState, staleDate: Date?)? {
        let rn = MedsEngine.rightNow(instances: instances, now: now, carryOver: carryOver)

        var window: NoFoodWindow?
        if case .noFood(let w) = rn.food, w.isConfirmed { window = w }

        let focus: DoseInstance?
        let isDue: Bool
        if let first = rn.due.first {
            focus = first
            isDue = true
        } else if let next = rn.next, next.scheduledAt.timeIntervalSince(now) <= upcomingLead {
            focus = next
            isDue = false
        } else {
            focus = nil
            isDue = false
        }

        // No meal while a no-food window runs.
        let meal = window == nil ? pickMeal(meals, now: now) : nil

        guard focus != nil || window != nil || meal != nil else { return nil }

        let dose = focus.map { instance in
            BloomActivityAttributes.DoseRef(
                medID: instance.medication.id.uuidString,
                scheduledAt: instance.scheduledAt,
                name: instance.medication.shortName,
                emoji: instance.medication.emoji,
                detail: instance.medication.dose,
                isDue: isDue
            )
        }

        // The next moment the content stops being accurate.
        var staleDate: Date?
        var reason = BloomActivityAttributes.StaleReason.none
        if let window {
            staleDate = window.end
            reason = .windowEnds
        }
        if let focus, !isDue, staleDate == nil || focus.scheduledAt < staleDate! {
            staleDate = focus.scheduledAt
            reason = .doseDue
        }
        if let meal, !meal.isDue, staleDate == nil || meal.startAt < staleDate! {
            staleDate = meal.startAt
            reason = .mealDue
        }

        let state = BloomActivityAttributes.ContentState(
            dose: dose,
            otherDueCount: max(0, rn.due.count - 1),
            windowStart: window?.start,
            windowEnd: window?.end,
            windowReason: window?.reasons.joined(separator: " & "),
            resolved: rn.resolvedToday,
            total: rn.totalToday,
            staleReason: reason,
            meal: meal
        )
        return (state, staleDate)
    }
}
