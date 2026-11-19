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
    /// Whether the note pops up once a day on opening the app; off leaves the "Note" pill and the morning notification.
    var notePopup = true
    /// How long the server writes the note: one or two lines, or the full page.
    var noteLength: NoteLength = .full
    private(set) var loaded = false
    private(set) var saveFailed = false

    enum NoteLength: String, CaseIterable, Sendable {
        case brief, full
        var label: String { self == .brief ? "Brief" : "Full" }
    }

    private static let cacheKey = "prefs.notification"

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: Self.cacheKey) {
            dailyNote = raw["daily_note"] as? Bool ?? true
            noteMinutes = raw["minutes"] as? Int ?? noteMinutes
            includeRecap = raw["include_recap"] as? Bool ?? true
            shareRecapWithPartner = raw["share"] as? Bool ?? true
            notePopup = raw["note_popup"] as? Bool ?? true
            noteLength = NoteLength(rawValue: raw["note_length"] as? String ?? "") ?? .full
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
        var note_popup: Bool?
        var note_length: String?
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

    /// The note popup / length settings couldn't be saved: the next load pushes the local values
    /// instead of reading the server's (so the server never clobbers an unsaved change).
    private static let notePrefsDirtyKey = "prefs.notePrefsDirty"
    private var notePrefsDirty: Bool {
        get { UserDefaults.standard.bool(forKey: Self.notePrefsDirtyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.notePrefsDirtyKey) }
    }

    /// Partner alerts (`notification_prefs.partner_alerts`); the store keeps the local copy as a cache.
    func setPartnerAlerts(_ enabled: Bool) async {
        AppStore.shared.setPartnerAlertsEnabled(enabled)
        partnerAlertsDirty = true
        await save()
    }

    func setNotePopup(_ enabled: Bool) async {
        notePopup = enabled
        notePrefsDirty = true
        await save()
    }

    func setNoteLength(_ length: NoteLength) async {
        noteLength = length
        notePrefsDirty = true
        await save()
    }

    /// Loads the row; creates it with the defaults when missing.
    func load() async {
        let store = AppStore.shared
        guard let uid = store.myUserID else { return }
        do {
            let rows: [Row] = try await Backend.client.from("notification_prefs")
                .select("user_id,pregnancy_id,daily_note,note_time,note_popup,note_length,include_recap,share_recap_with_partner,partner_alerts")
                .eq("user_id", value: uid)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                dailyNote = row.daily_note
                noteMinutes = Self.minutes(row.note_time) ?? noteMinutes
                includeRecap = row.include_recap
                shareRecapWithPartner = row.share_recap_with_partner
                var needsSave = row.pregnancy_id != store.account?.pregnancyID
                if notePrefsDirty {
                    // A change this phone hasn't saved yet wins over the server's row.
                    needsSave = true
                } else {
                    notePopup = row.note_popup ?? true
                    noteLength = NoteLength(rawValue: row.note_length ?? "") ?? .full
                }
                cache()
                loaded = true
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
                      note_time: Self.timeString(noteMinutes), note_popup: notePopup,
                      note_length: noteLength.rawValue, include_recap: includeRecap,
                      share_recap_with_partner: shareRecapWithPartner,
                      partner_alerts: store.partnerAlertsEnabled)
        do {
            try await Backend.client.from("notification_prefs")
                .upsert(row, onConflict: "user_id")
                .execute()
            saveFailed = false
            partnerAlertsDirty = false
            notePrefsDirty = false
        } catch {
            saveFailed = true
        }
        // Best effort, separate from the row above: the partner alert shows "no food until 8:31" in local time.
        // Fails quietly where the time_zone column hasn't been added yet.
        struct Zone: Encodable { var time_zone: String }
        _ = try? await Backend.client.from("notification_prefs")
            .update(Zone(time_zone: TimeZone.current.identifier))
            .eq("user_id", value: uid)
            .execute()
        PushRegistry.shared.setPartnerAlerts(enabled: store.partnerAlertsEnabled)
    }

    private func cache() {
        UserDefaults.standard.set([
            "daily_note": dailyNote, "minutes": noteMinutes,
            "include_recap": includeRecap, "share": shareRecapWithPartner,
            "note_popup": notePopup, "note_length": noteLength.rawValue,
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
