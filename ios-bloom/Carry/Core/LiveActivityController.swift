import Foundation
import ActivityKit

/// Starts, updates and ends the meds Live Activities from the app's state.
/// One activity per person whose meds this phone follows live ("taker group").
/// Activities started here are a fallback: when shared, the server also starts and updates
/// them on both phones with push tokens registered by `PushRegistry`.
@MainActor
enum LiveActivityController {
    private static var lastStates: [String: BloomActivityAttributes.ContentState] = [:]

    // MARK: - Newest per taker

    /// activity.id → when this phone first saw it. ActivityKit has no start date, so this
    /// decides which of two cards for the same person is the newest.
    private static var firstSeen: [String: Date] = {
        let raw = UserDefaults.standard.dictionary(forKey: "liveActivity.firstSeen") as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }() {
        didSet {
            let running = Set(Activity<BloomActivityAttributes>.activities.map(\.id))
            let raw = firstSeen.filter { running.contains($0.key) }.mapValues(\.timeIntervalSince1970)
            UserDefaults.standard.set(raw, forKey: "liveActivity.firstSeen")
        }
    }

    static func noteSeen(_ activity: Activity<BloomActivityAttributes>) {
        if firstSeen[activity.id] == nil { firstSeen[activity.id] = .now }
    }

    private static func isLive(_ a: Activity<BloomActivityAttributes>) -> Bool {
        a.activityState == .active || a.activityState == .stale
    }

    /// The newest running activity in the list (unknown ages count as oldest; ties go to the later one).
    private static func newest(_ list: [Activity<BloomActivityAttributes>]) -> Activity<BloomActivityAttributes>? {
        let live = list.filter(isLive)
        for a in live { noteSeen(a) }
        var best: Activity<BloomActivityAttributes>?
        for a in live where best == nil || (firstSeen[a.id] ?? .distantPast) >= (firstSeen[best!.id] ?? .distantPast) {
            best = a
        }
        return best
    }

    /// A new card for a person who already has one on this phone: the older one ends right away.
    static func endOlderDuplicates(keeping activity: Activity<BloomActivityAttributes>) {
        guard isLive(activity) else { return }
        let taker = activity.attributes.takerID.lowercased()
        let older = Activity<BloomActivityAttributes>.activities.filter {
            $0.id != activity.id && $0.attributes.takerID.lowercased() == taker && isLive($0)
        }
        guard !older.isEmpty else { return }
        lastStates[taker] = nil
        end(older, takerID: nil, immediately: true)
    }

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
        var remaining = Activity<BloomActivityAttributes>.activities
        // Push-started cards too: make sure every running one's update token is uploaded.
        if store.isShared { remaining.forEach { PushRegistry.shared.observe($0) } }

        let groups = (store.liveActivitiesEnabled && store.isOnboarded) ? groups(store: store) : []

        for group in groups {
            let mine = remaining.filter { $0.attributes.takerID.lowercased() == group.takerID }
            remaining.removeAll { a in mine.contains { $0.id == a.id } }

            let instances = MedsEngine.instances(on: now, medications: group.medications, logs: store.doseLogs)
            guard let content = LiveActivityContent.make(
                instances: instances, now: now,
                carryOver: MedsEngine.carryOver(into: now, medications: group.medications, logs: store.doseLogs),
                meals: uneatenMeals(store: store, owner: group.role, now: now)
            ) else {
                let resolved = instances.filter { !$0.isPending }.count
                end(mine, takerID: group.takerID, final: .init(dose: nil, otherDueCount: 0, windowStart: nil, windowEnd: nil,
                                                             windowReason: nil, resolved: resolved, total: instances.count,
                                                             staleReason: .none))
                continue
            }

            let activityContent = ActivityContent(state: content.state, staleDate: content.staleDate, relevanceScore: 100)
            if let activity = newest(mine) {
                end(mine.filter { $0.id != activity.id }, takerID: group.takerID, immediately: true)
                guard content.state != lastStates[group.takerID]
                        || activity.content.state != content.state
                        || activity.activityState == .stale else { continue }
                lastStates[group.takerID] = content.state
                Task { await activity.update(activityContent) }
            } else {
                // A lingering "all done" card would contradict the new dose, so clear it first.
                end(mine, takerID: group.takerID, immediately: true)
                let attributes = BloomActivityAttributes(
                    momName: store.profile?.momName ?? "",
                    takerID: group.takerID,
                    takerName: group.name,
                    takerRole: group.role.rawValue
                )
                do {
                    let activity = try Activity.request(attributes: attributes, content: activityContent,
                                                        pushType: store.isShared ? .token : nil)
                    noteSeen(activity)
                    lastStates[group.takerID] = content.state
                    // activityUpdates doesn't report activities this app started, so upload its token here.
                    if store.isShared { PushRegistry.shared.observe(activity) }
                } catch {
                    // Push tokens can be unavailable (e.g. no APNs on this device); fall back to a local activity.
                    if store.isShared, let activity = try? Activity.request(attributes: attributes, content: activityContent, pushType: nil) {
                        noteSeen(activity)
                        lastStates[group.takerID] = content.state
                    }
                    // Otherwise not allowed right now (e.g. app in background); the next foreground sync retries.
                }
            }
        }

        // Activities for people no longer followed, or from before sharing changed.
        end(remaining, takerID: nil, immediately: true)
    }

    /// Today's routine meals (the day's own set, else the routine's) not logged yet.
    static func uneatenMeals(store: AppStore, owner: MedOwner, now: Date) -> [LiveActivityContent.MealSlot] {
        let start = PregnancyMath.calendar.startOfDay(for: now)
        return store.checkableMeals(owner, on: now).compactMap { kind, meal in
            guard store.mealLog(owner, on: now, kind: kind) == nil else { return nil }
            let begins = meal.time.date(on: start)
            return LiveActivityContent.MealSlot(kind: kind, name: meal.name, start: begins,
                                                end: begins.addingTimeInterval(Double(meal.durationMinutes) * 60))
        }
    }

    static func endAll() {
        lastStates = [:]
        end(Activity<BloomActivityAttributes>.activities, takerID: nil, immediately: true)
    }

    /// Ends with an "all caught up" state that lingers for a while, unless `immediately`.
    private static func end(
        _ activities: [Activity<BloomActivityAttributes>],
        takerID: String?,
        final: BloomActivityAttributes.ContentState? = nil,
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
