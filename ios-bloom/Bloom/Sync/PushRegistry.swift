import Foundation
import ActivityKit
import Supabase

/// Keeps `device_tokens` in step with this phone's push tokens:
/// - `apns`: regular notifications (partner alerts), only while partner alerts are on.
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
    /// activity.id → (token, takerID)
    private var updateTokens: [String: (token: String, takerID: String)] = [:]
    private var observedActivities: Set<String> = []

    private init() {
        apnsToken = UserDefaults.standard.string(forKey: "push.apns")
        startToken = UserDefaults.standard.string(forKey: "push.start")
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
        Task {
            for await activity in Activity<BloomActivityAttributes>.activityUpdates {
                self.observe(activity)
            }
        }
    }

    private func observe(_ activity: Activity<BloomActivityAttributes>) {
        guard !observedActivities.contains(activity.id) else { return }
        observedActivities.insert(activity.id)
        let takerID = activity.attributes.takerID

        Task {
            for await data in activity.pushTokenUpdates {
                let hex = data.hexString
                if let old = self.updateTokens[activity.id], old.token == hex { continue }
                self.updateTokens[activity.id] = (hex, takerID)
                await self.upsert(token: hex, kind: .update, activityID: "\(takerID):\(activity.id)")
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    if let entry = self.updateTokens.removeValue(forKey: activity.id) {
                        await self.delete(token: entry.token, kind: .update)
                    }
                    self.observedActivities.remove(activity.id)
                    break
                }
            }
        }
    }

    /// Re-sends every known token (after sign-in, joining, or a pregnancy change).
    func registerAll() {
        Task {
            if let startToken { await upsert(token: startToken, kind: .start, activityID: nil) }
            for (activityID, entry) in updateTokens {
                await upsert(token: entry.token, kind: .update, activityID: "\(entry.takerID):\(activityID)")
            }
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
        if AppStore.shared.partnerAlertsEnabled {
            await upsert(token: apnsToken, kind: .apns, activityID: nil)
        } else {
            await delete(token: apnsToken, kind: .apns)
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
        guard let uid = store.myUserID, let pid = store.account?.pregnancyID else { return }
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
        } catch {
            // Retried on the next registerAll (launch, foreground, sign-in).
        }
    }

    private func delete(token: String, kind: Kind) async {
        guard AppStore.shared.myUserID != nil else { return }
        do {
            try await Backend.client.from("device_tokens")
                .delete()
                .eq("token", value: token)
                .eq("type", value: kind.rawValue)
                .execute()
        } catch {}
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
