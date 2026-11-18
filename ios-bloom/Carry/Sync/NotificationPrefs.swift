import Foundation
import Observation
import Supabase

/// The morning note settings, one `notification_prefs` row per user (PK `user_id`).
/// The server writes and sends the note; nothing is scheduled on the phone.
@MainActor
@Observable
final class NotificationPrefs {
    static let shared = NotificationPrefs()

    var dailyNote = true
    /// Minutes after midnight.
    var noteMinutes = 8 * 60 + 30
    var includeRecap = true
    var shareRecapWithPartner = true
    private(set) var loaded = false
    private(set) var saveFailed = false

    private static let cacheKey = "prefs.notification"

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: Self.cacheKey) {
            dailyNote = raw["daily_note"] as? Bool ?? true
            noteMinutes = raw["minutes"] as? Int ?? noteMinutes
            includeRecap = raw["include_recap"] as? Bool ?? true
            shareRecapWithPartner = raw["share"] as? Bool ?? true
        }
    }

    /// Whether this phone's APNs token should be registered (morning note on, read by PushRegistry).
    nonisolated static var dailyNoteCached: Bool {
        (UserDefaults.standard.dictionary(forKey: cacheKey)?["daily_note"] as? Bool) ?? true
    }

    private struct Row: Codable {
        var user_id: UUID
        var pregnancy_id: UUID?
        var daily_note: Bool
        var note_time: String
        var include_recap: Bool
        var share_recap_with_partner: Bool
        var partner_alerts: Bool?
    }

    /// The Partner alerts toggle couldn't be saved: the next load pushes the local value instead of reading it.
    private static let partnerAlertsDirtyKey = "prefs.partnerAlertsDirty"
    private var partnerAlertsDirty: Bool {
        get { UserDefaults.standard.bool(forKey: Self.partnerAlertsDirtyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.partnerAlertsDirtyKey) }
    }

    /// Partner alerts (`notification_prefs.partner_alerts`); the store keeps the local copy as a cache.
    func setPartnerAlerts(_ enabled: Bool) async {
        AppStore.shared.setPartnerAlertsEnabled(enabled)
        partnerAlertsDirty = true
        await save()
    }

    /// Loads the row; creates it with the defaults when missing.
    func load() async {
        let store = AppStore.shared
        guard let uid = store.myUserID else { return }
        do {
            let rows: [Row] = try await Backend.client.from("notification_prefs")
                .select("user_id,pregnancy_id,daily_note,note_time,include_recap,share_recap_with_partner,partner_alerts")
                .eq("user_id", value: uid)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                dailyNote = row.daily_note
                noteMinutes = Self.minutes(row.note_time) ?? noteMinutes
                includeRecap = row.include_recap
                shareRecapWithPartner = row.share_recap_with_partner
                cache()
                loaded = true
                var needsSave = row.pregnancy_id != store.account?.pregnancyID
                if partnerAlertsDirty {
                    needsSave = true
                } else if let remote = row.partner_alerts, remote != store.partnerAlertsEnabled {
                    store.setPartnerAlertsEnabled(remote)
                    PushRegistry.shared.setPartnerAlerts(enabled: remote)
                }
                if needsSave { await save() }
            } else {
                loaded = true
                await save()
            }
        } catch {
            loaded = true
        }
    }

    func save() async {
        cache()
        let store = AppStore.shared
        guard let uid = store.myUserID else { return }
        let row = Row(user_id: uid, pregnancy_id: store.account?.pregnancyID, daily_note: dailyNote,
                      note_time: Self.timeString(noteMinutes), include_recap: includeRecap,
                      share_recap_with_partner: shareRecapWithPartner,
                      partner_alerts: store.partnerAlertsEnabled)
        do {
            try await Backend.client.from("notification_prefs")
                .upsert(row, onConflict: "user_id")
                .execute()
            saveFailed = false
            partnerAlertsDirty = false
        } catch {
            saveFailed = true
        }
        PushRegistry.shared.setPartnerAlerts(enabled: store.partnerAlertsEnabled)
    }

    private func cache() {
        UserDefaults.standard.set([
            "daily_note": dailyNote, "minutes": noteMinutes,
            "include_recap": includeRecap, "share": shareRecapWithPartner,
        ], forKey: Self.cacheKey)
    }

    static func timeString(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
