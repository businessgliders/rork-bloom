import Foundation
import Supabase

// MARK: - Local account state (persisted in the state file)

/// How one person follows one medication. Raw values match `medication_follows.mode`.
nonisolated enum FollowMode: String, Codable, CaseIterable, Identifiable {
    case live
    case appOnly = "app_only"

    var id: String { rawValue }
    var title: String { self == .live ? "Live + alerts" : "App only" }
}

nonisolated struct AccountMember: Codable, Equatable, Identifiable {
    var userID: UUID
    var role: MedOwner
    var displayName: String
    var id: UUID { userID }
}

/// Who is signed in on this phone and which shared pregnancy they belong to.
nonisolated struct SyncAccount: Codable, Equatable {
    var userID: UUID
    var pregnancyID: UUID?
    var myRole: MedOwner = .mom
    var inviteCode: String?
    var creatorID: UUID?
    var members: [AccountMember] = []

    var partnerJoined: Bool { members.count > 1 }
}

/// A local change waiting to be sent. Flushing reconciles to the current local state,
/// so the op only says *what* changed, not how.
nonisolated struct SyncOp: Codable, Equatable {
    nonisolated enum Kind: String, Codable, CaseIterable {
        // Order = flush order: templates and rules need their medications on the server first.
        case profile, medication, template, rule, plan, follow, milestone, dose, medText, meal

        var order: Int { Kind.allCases.firstIndex(of: self) ?? 0 }
    }

    var kind: Kind
    var key: String
    /// For deletions/replacements: the remote photo path that should be removed.
    var photoPath: String?
    var seq: Int

    static func doseKey(medicationID: UUID, scheduledAt: Date) -> String {
        "\(medicationID.uuidString)|\(Int(scheduledAt.timeIntervalSince1970.rounded()))"
    }

    static func parseDoseKey(_ key: String) -> (UUID, Date)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let stamp = Double(parts[1]) else { return nil }
        return (id, Date(timeIntervalSince1970: stamp))
    }
}

// MARK: - Remote rows (read side)

nonisolated struct RemotePregnancyRow: Decodable {
    var id: UUID
    var created_by: UUID
    var creator_role: String
    var mom_name: String
    var partner_name: String?
    var baby_nickname: String?
    var dating_method: String
    var dating_date: String
    var due_date: String
    var invite_code: String
}

nonisolated struct RemoteMemberRow: Decodable {
    var pregnancy_id: UUID
    var user_id: UUID
    var role: String
}

nonisolated struct RemoteProfileRow: Decodable {
    var id: UUID
    var display_name: String?
}

nonisolated struct RemoteMilestoneRow: Decodable {
    var id: UUID
    var title: String
    var type: String
    var occurs_at: Date?
    var notes: String?
    var photo_path: String?
    var is_suggested: Bool?
    var completed: Bool?
}

nonisolated struct RemoteMedicationRow: Decodable {
    var id: UUID
    var name: String
    var dose: String?
    var purpose: String?
    var schedule_type: String
    var days_of_week: [Int]?
    /// Null for medications scheduled by templates (round 1).
    var time_of_day: String?
    var food_rule: String
    var no_food_before_min: Int?
    var no_food_after_min: Int?
    var rules_confirmed: Bool?
    var notes: String?
    var start_date: String?
    var end_date: String?
    var taken_by: UUID
    var friendly_name: String?
    var photo_path: String?
    var created_at: Date?
}

nonisolated struct RemoteFollowRow: Decodable {
    var medication_id: UUID
    var user_id: UUID
    var mode: String
}

nonisolated struct RemoteDoseRow: Decodable {
    var id: UUID
    var medication_id: UUID
    var scheduled_for: Date
    var status: String
    var taken_at: Date?
    var logged_by: UUID?
}

nonisolated struct RemoteIDRow: Decodable {
    var id: UUID
}

nonisolated struct RemoteTemplateRow: Decodable {
    var id: UUID
    var taker_id: UUID
    var name: String
    var days_of_week: [Int]?
    var wake_time: String
    var bed_time: String
    var meals: [RemoteMealJSON]?
    var active: Bool?
    var updated_at: Date?
}

/// One entry of `schedule_templates.meals`.
nonisolated struct RemoteMealJSON: Decodable {
    var id: String?
    var name: String
    var time: String
    var duration_min: Int?
}

nonisolated struct RemoteTemplateItemRow: Decodable {
    var id: UUID
    var template_id: UUID
    var kind: String
    var medication_id: UUID?
    var label: String?
    var time_of_day: String
    var duration_min: Int?
    var sort_order: Int?
    var pinned: Bool?
}

nonisolated struct RemoteRuleRow: Decodable {
    var id: UUID
    var taker_id: UUID
    var subject_medication_id: UUID
    var relation: String
    var target_type: String
    var target_medication_id: UUID?
    var target_meal: String?
    var min_minutes: Int?
    var max_minutes: Int?
    var source_text: String?
    var confirmed: Bool?
}

nonisolated struct RemotePlannedDoseRow: Decodable {
    var id: UUID
    var taker_id: UUID
    var medication_id: UUID
    var local_date: String
    var scheduled_for: Date
    var source: String
    var template_id: UUID?
    /// `meal_adjust` rows: "reason:meal:from".
    var meal_reason: String?
}

/// `meal_logs`: a meal checked off on Meds today. `eaten_at` is when the meal ended.
nonisolated struct RemoteMealLogRow: Decodable {
    var id: UUID
    var taker_id: UUID
    var local_date: String
    var meal: String
    var planned_at: Date?
    var eaten_at: Date
    var logged_by: UUID?
    var updated_at: Date?
}

/// `day_routines`: one person's own wake, bed and meals for one day ("Just today").
nonisolated struct RemoteDayRoutineRow: Decodable {
    struct Meal: Codable {
        var id: UUID
        var name: String
        var time: String
        var duration_min: Int?
    }

    var id: UUID
    var taker_id: UUID
    var local_date: String
    var template_id: UUID?
    var wake_time: String?
    var bed_time: String?
    var meals: [Meal]?
}

/// `med_texts`: one person's "My rules" exactly as typed.
nonisolated struct RemoteMedTextRow: Decodable {
    var taker_id: UUID
    var text: String
    var updated_by: UUID?
    var updated_at: Date?
}

// MARK: - Formatting helpers

nonisolated enum SyncFormat {
    /// `date` columns: a local calendar day.
    static func day(_ date: Date) -> String {
        let c = PregnancyMath.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    static func day(from string: String?) -> Date? {
        guard let string else { return nil }
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return PregnancyMath.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `time` columns: "HH:mm:00".
    static func time(_ time: DoseTime) -> String {
        String(format: "%02d:%02d:00", time.hour, time.minute)
    }

    static func time(from string: String) -> DoseTime {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        return DoseTime(hour: parts.first ?? 8, minute: parts.count > 1 ? parts[1] : 0)
    }

    /// `timestamptz` columns.
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func text(_ string: String) -> AnyJSON {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .null : .string(trimmed)
    }

    static func optional(_ string: String?) -> AnyJSON {
        string.map { .string($0) } ?? .null
    }
}
