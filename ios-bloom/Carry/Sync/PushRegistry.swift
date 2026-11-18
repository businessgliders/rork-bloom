import Foundation
import ActivityKit
import Supabase

/// Keeps `device_tokens` in step with this phone's push tokens:
/// - `apns`: regular notifications (the morning note, partner alerts), while either is on.
/// - `live_activity_start`: push-to-start token for the meds Live Activity.
/// - `live_activity_update`: one per running activity, `activity_id` = "{takerID}:{activityID}".
/// The server (the user's Edge Function) uses these to start, update and end activities on both phones.
@MainActor
final class PushRegistry {
    static let shared = PushRegistry()

    private enum Kind: String { case apns, start = "live_activity_start", update = "live_activity_update" }

    private var started = false
    private var apnsToken: String? {
        didSet { UserDefaults.standard.set(apnsToken, forKey: "push.apns") }
    }
    private var startToken: String? {
        didSet { UserDefaults.standard.set(startToken, forKey: "push.start") }
    }
    /// activity.id → (token, takerID). Saved so a row can still be deleted after a relaunch
    /// when the activity ended while the app wasn't running.
    private var updateTokens: [String: (token: String, takerID: String)] = [:] {
        didSet {
            let raw = updateTokens.mapValues { [$0.token, $0.takerID] }
            UserDefaults.standard.set(raw, forKey: "push.update")
        }
    }
    private var observedActivities: Set<String> = []
    /// The last failed `device_tokens` write (hidden debug info). Cleared by the next success.
    private(set) var lastUploadError: String?
    private(set) var lastUploadErrorAt: Date?
    /// A write failed; the next foreground's `registerAll` re-sends everything.
    private(set) var needsRetry = false
    /// Update tokens the server accepted, keyed by activity id.
    private(set) var uploadedUpdateTokens: Set<String> = []

    /// Whether a running activity has an update token on file (and whether it reached the server).
    var updateTokenSummary: String {
        let running = Set(Activity<BloomActivityAttributes>.activities.filter { !Self.isOver($0.activityState) }.map(\.id))
        let known = updateTokens.keys.filter { running.contains($0) }
        if known.isEmpty { return running.isEmpty ? "no activity running" : "none (\(running.count) running)" }
        let sent = known.filter { uploadedUpdateTokens.contains($0) }.count
        return "\(known.count) token\(known.count == 1 ? "" : "s"), \(sent) uploaded"
    }

    private init() {
        apnsToken = UserDefaults.standard.string(forKey: "push.apns")
        startToken = UserDefaults.standard.string(forKey: "push.start")
        let raw = UserDefaults.standard.dictionary(forKey: "push.update") as? [String: [String]] ?? [:]
        updateTokens = raw.compactMapValues { $0.count == 2 ? (token: $0[0], takerID: $0[1]) : nil }
    }

    private static func isOver(_ state: ActivityState) -> Bool {
        state == .ended || state == .dismissed
    }

    func start() {
        guard !started else { return }
        started = true

        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<BloomActivityAttributes>.pushToStartTokenUpdates {
                    let hex = data.hexString
                    guard hex != self.startToken else { continue }
                    self.startToken = hex
                    await self.upsert(token: hex, kind: .start, activityID: nil)
                }
            }
        }

        for activity in Activity<BloomActivityAttributes>.activities {
            observe(activity)
        }
        Task { await sweepEnded() }
        Task {
            for await activity in Activity<BloomActivityAttributes>.activityUpdates {
                // Usually one the server push-started. Keep only the newest per taker.
                LiveActivityController.noteSeen(activity)
                self.observe(activity)
                LiveActivityController.endOlderDuplicates(keeping: activity)
            }
        }
    }

    /// Uploads the activity's update tokens. Called for activities this app starts itself
    /// (`activityUpdates` doesn't report those) and for push-started ones.
    func observe(_ activity: Activity<BloomActivityAttributes>) {
        guard !observedActivities.contains(activity.id) else { return }
        let takerID = activity.attributes.takerID
        // Already over (e.g. ended while the app was closed): just clean up its row.
        if Self.isOver(activity.activityState) {
            Task { await self.removeUpdateToken(activityID: activity.id, takerID: takerID) }
            return
        }
        observedActivities.insert(activity.id)

        Task {
            for await data in activity.pushTokenUpdates {
                guard !Self.isOver(activity.activityState) else { break }
                let hex = data.hexString
                if let old = self.updateTokens[activity.id], old.token == hex { continue }
                self.updateTokens[activity.id] = (hex, takerID)
                await self.upsert(token: hex, kind: .update, activityID: "\(takerID):\(activity.id)")
            }
        }
        Task {
            for await state in activity.activityStateUpdates where Self.isOver(state) {
                await self.removeUpdateToken(activityID: activity.id, takerID: takerID)
                self.observedActivities.remove(activity.id)
                break
            }
        }
    }

    /// Called right after the app ends an activity, so the row goes even if the state stream is late.
    func activityEnded(_ activity: Activity<BloomActivityAttributes>) {
        Task { await removeUpdateToken(activityID: activity.id, takerID: activity.attributes.takerID) }
    }

    /// Deletes rows for saved activities that are no longer running on this phone.
    private func sweepEnded() async {
        let running = Set(Activity<BloomActivityAttributes>.activities
            .filter { !Self.isOver($0.activityState) }
            .map(\.id))
        for (activityID, entry) in updateTokens where !running.contains(activityID) {
            await removeUpdateToken(activityID: activityID, takerID: entry.takerID)
        }
    }

    /// Removes the `live_activity_update` row by token and by activity id.
    private func removeUpdateToken(activityID: String, takerID: String) async {
        let entry = updateTokens[activityID]
        guard AppStore.shared.myUserID != nil else { return }
        var ok = true
        if let entry { ok = await delete(token: entry.token, kind: .update) }
        do {
            try await Backend.client.from("device_tokens")
                .delete()
                .eq("type", value: Kind.update.rawValue)
                .eq("activity_id", value: "\(takerID):\(activityID)")
                .execute()
        } catch { ok = false }
        // Keep the entry on failure so the next launch or foreground retries.
        if ok {
            updateTokens[activityID] = nil
            uploadedUpdateTokens.remove(activityID)
        }
    }

    /// Re-sends every known token (sign-in, joining, a pregnancy change, and every foreground).
    /// Each upsert bumps the row's updated_at; the server drops update tokens unheard of for 8 h.
    func registerAll() {
        start()
        // Activities started while the observers weren't running yet.
        for activity in Activity<BloomActivityAttributes>.activities { observe(activity) }
        Task {
            needsRetry = false
            await sweepEnded()
            if let startToken { await upsert(token: startToken, kind: .start, activityID: nil) }
            for (activityID, entry) in updateTokens {
                await upsert(token: entry.token, kind: .update, activityID: "\(entry.takerID):\(activityID)")
            }
            // Creates the notification_prefs row with the defaults when missing.
            await NotificationPrefs.shared.load()
            await syncAPNs()
        }
    }

    func setAPNsToken(_ data: Data) {
        let hex = data.hexString
        guard hex != apnsToken else { return }
        apnsToken = hex
        Task { await syncAPNs() }
    }

    func setPartnerAlerts(enabled: Bool) {
        Task { await syncAPNs() }
    }

    private func syncAPNs() async {
        guard let apnsToken else { return }
        if AppStore.shared.partnerAlertsEnabled || NotificationPrefs.dailyNoteCached {
            await upsert(token: apnsToken, kind: .apns, activityID: nil)
        } else {
            _ = await delete(token: apnsToken, kind: .apns)
        }
    }

    /// Removes every token row this user owns (sign out, leave, delete account).
    func removeMyTokens() async {
        guard let uid = AppStore.shared.myUserID else { return }
        do {
            try await Backend.client.from("device_tokens").delete().eq("user_id", value: uid).execute()
        } catch {
            // Best effort; rows of a deleted user are removed server-side.
        }
    }

    // MARK: - Writes

    private func upsert(token: String, kind: Kind, activityID: String?) async {
        let store = AppStore.shared
        guard let uid = store.myUserID, let pid = store.account?.pregnancyID else {
            // Not signed in or not shared yet: sent by registerAll once it is.
            needsRetry = true
            return
        }
        let payload: [String: AnyJSON] = [
            "token": .string(token),
            "type": .string(kind.rawValue),
            "pregnancy_id": .string(pid.uuidString),
            "activity_id": activityID.map { AnyJSON.string($0) } ?? .null,
            "user_id": .string(uid.uuidString),
            "environment": .string(APNsEnvironment.current.rawValue),
        ]
        do {
            try await Backend.client.from("device_tokens")
                .upsert(payload, onConflict: "token,type")
                .execute()
            if kind == .update, let activityID, let id = activityID.split(separator: ":").last.map(String.init) {
                uploadedUpdateTokens.insert(id)
            }
            lastUploadError = nil
        } catch {
            // Retried on the next registerAll (every foreground, sign-in).
            needsRetry = true
            lastUploadError = "\(kind.rawValue): \(error.localizedDescription)"
            lastUploadErrorAt = .now
        }
    }

    @discardableResult
    private func delete(token: String, kind: Kind) async -> Bool {
        guard AppStore.shared.myUserID != nil else { return false }
        do {
            try await Backend.client.from("device_tokens")
                .delete()
                .eq("token", value: token)
                .eq("type", value: kind.rawValue)
                .execute()
            return true
        } catch {
            return false
        }
    }
}

/// Which APNs host the tokens from this build belong to (`device_tokens.environment`).
/// - Simulator and Debug builds: `sandbox`.
/// - A build with an embedded provisioning profile (development or ad hoc) uses that profile's
///   `aps-environment` ("development" means sandbox).
/// - TestFlight and App Store builds have no embedded profile and always use `production`.
nonisolated enum APNsEnvironment: String {
    case sandbox, production

    static let current: APNsEnvironment = detect()

    private static func detect() -> APNsEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        if let fromProfile = profileEnvironment() { return fromProfile }
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
        #endif
    }

    /// Reads `aps-environment` from embedded.mobileprovision, or nil when the build has none.
    private static func profileEnvironment() -> APNsEnvironment? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return nil }
        let rest = text[key.upperBound...]
        guard let open = rest.range(of: "<string>"),
              let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex) else { return nil }
        let value = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "development" ? .sandbox : .production
    }
}

nonisolated extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
