import Foundation
import ActivityKit

/// Starts, updates and ends the meds Live Activities from the app's state.
/// One activity per person whose meds this phone follows live ("taker group").
/// Activities started here are a fallback: when shared, the server also starts and updates
/// them on both phones with push tokens registered by `PushRegistry`.
@MainActor
enum LiveActivityController {
    private static var lastStates: [String: CarryActivityAttributes.ContentState] = [:]

    private struct TakerGroup {
        var takerID: String
        var role: MedOwner
        var name: String
        var medications: [Medication]
    }

    private static func groups(store: AppStore) -> [TakerGroup] {
        let live = store.liveMedications
        return MedOwner.allCases.compactMap { role in
            let meds = live.filter { $0.owner == role }
            guard !meds.isEmpty else { return nil }
            let takerID: String
            if store.isShared {
                takerID = store.memberID(for: role)?.uuidString.lowercased() ?? "local-\(role.rawValue)"
            } else {
                takerID = "local"
            }
            return TakerGroup(takerID: takerID, role: role, name: store.name(for: role), medications: meds)
        }
    }

    static func sync(store: AppStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date.now
        var remaining = Activity<CarryActivityAttributes>.activities

        let groups = (store.liveActivitiesEnabled && store.isOnboarded) ? groups(store: store) : []

        for group in groups {
            let mine = remaining.filter { $0.attributes.takerID.lowercased() == group.takerID }
            remaining.removeAll { a in mine.contains { $0.id == a.id } }

            let instances = MedsEngine.instances(on: now, medications: group.medications, logs: store.doseLogs)
            guard let content = LiveActivityContent.make(
                instances: instances, now: now,
                carryOver: MedsEngine.carryOver(into: now, medications: group.medications, logs: store.doseLogs)
            ) else {
                let resolved = instances.filter { !$0.isPending }.count
                end(mine, takerID: group.takerID, final: .init(dose: nil, otherDueCount: 0, windowStart: nil, windowEnd: nil,
                                                             windowReason: nil, resolved: resolved, total: instances.count,
                                                             staleReason: .none))
                continue
            }

            let activityContent = ActivityContent(state: content.state, staleDate: content.staleDate, relevanceScore: 100)
            if let activity = mine.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
                end(mine.filter { $0.id != activity.id }, takerID: group.takerID, immediately: true)
                guard content.state != lastStates[group.takerID]
                        || activity.content.state != content.state
                        || activity.activityState == .stale else { continue }
                lastStates[group.takerID] = content.state
                Task { await activity.update(activityContent) }
            } else {
                // A lingering "all done" card would contradict the new dose, so clear it first.
                end(mine, takerID: group.takerID, immediately: true)
                let attributes = CarryActivityAttributes(
                    momName: store.profile?.momName ?? "",
                    takerID: group.takerID,
                    takerName: group.name,
                    takerRole: group.role.rawValue
                )
                do {
                    _ = try Activity.request(attributes: attributes, content: activityContent,
                                             pushType: store.isShared ? .token : nil)
                    lastStates[group.takerID] = content.state
                } catch {
                    // Push tokens can be unavailable (e.g. no APNs on this device); fall back to a local activity.
                    if store.isShared, (try? Activity.request(attributes: attributes, content: activityContent, pushType: nil)) != nil {
                        lastStates[group.takerID] = content.state
                    }
                    // Otherwise not allowed right now (e.g. app in background); the next foreground sync retries.
                }
            }
        }

        // Activities for people no longer followed, or from before sharing changed.
        end(remaining, takerID: nil, immediately: true)
    }

    static func endAll() {
        lastStates = [:]
        end(Activity<CarryActivityAttributes>.activities, takerID: nil, immediately: true)
    }

    /// Ends with an "all caught up" state that lingers for a while, unless `immediately`.
    private static func end(
        _ activities: [Activity<CarryActivityAttributes>],
        takerID: String?,
        final: CarryActivityAttributes.ContentState? = nil,
        immediately: Bool = false
    ) {
        let live = activities.filter { $0.activityState == .active || $0.activityState == .stale || immediately }
        guard !live.isEmpty else { return }
        if let takerID { lastStates[takerID] = nil }
        let finalContent = final.map { ActivityContent(state: $0, staleDate: nil) }
        for activity in live {
            Task {
                await activity.end(finalContent, dismissalPolicy: immediately ? .immediate : .after(.now.addingTimeInterval(30 * 60)))
                PushRegistry.shared.activityEnded(activity)
            }
        }
    }
}
