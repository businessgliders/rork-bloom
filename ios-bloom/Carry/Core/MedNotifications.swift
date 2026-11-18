import Foundation
import UserNotifications

/// Local reminders for doses and food windows. Everything is computed on device from
/// the medication list and dose logs, and fully rebuilt after every change.
enum MedNotifications {
    static let doseCategory = "DOSE"
    nonisolated static let takenAction = "TAKEN"
    nonisolated static let snoozeAction = "SNOOZE"
    static let snoozeMinutes = 10
    private static let snoozePrefix = "snooze-"
    private static let prefixes = ["dose-", "prefast-", "foodok-"]
    private static let maxRequests = 60

    static func registerCategories() {
        let taken = UNNotificationAction(
            identifier: takenAction, title: "Taken", options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle.fill")
        )
        let snooze = UNNotificationAction(
            identifier: snoozeAction, title: "Snooze \(snoozeMinutes) min", options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")
        )
        let category = UNNotificationCategory(identifier: doseCategory, actions: [taken, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func removeAll() {
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { id in (prefixes + [snoozePrefix]).contains { id.hasPrefix($0) } }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Re-delivers the same dose reminder in 10 minutes.
    static func snooze(_ content: UNNotificationContent) async {
        guard let medID = content.userInfo["medID"] as? String,
              let stamp = content.userInfo["scheduledAt"] as? Double,
              let copy = content.mutableCopy() as? UNMutableNotificationContent else { return }
        copy.title = content.title
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(snoozeMinutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: "\(snoozePrefix)\(medID)-\(Int(stamp))", content: copy, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// One person's live-followed meds. `person` is nil for the viewer's own meds ("you" wording).
    struct Group {
        var person: String?
        var medications: [Medication]
    }

    /// Rebuilds reminders for the meds this phone follows live, grouped by who takes them.
    @MainActor
    static func reschedule(store: AppStore) {
        let live = store.liveMedications
        let owners = Array(Set(live.map(\.owner))).sorted { $0.rawValue < $1.rawValue }
        let groups = owners.map { owner in
            Group(
                person: (!store.isShared || owner == store.viewerRole) ? nil : store.name(for: owner),
                medications: live.filter { $0.owner == owner }
            )
        }
        reschedule(groups: groups, logs: store.doseLogs)
    }

    static func reschedule(groups: [Group], logs: [DoseLog]) {
        let now = Date.now
        // Nearest first, so today's and tomorrow's are never the ones cut by iOS's 64-request limit.
        let requests = groups
            .flatMap { buildRequests(group: $0, logs: logs, now: now) }
            .sorted { $0.date < $1.date }
            .map(\.request)
        // Snoozes for doses that are no longer pending (logged, deleted, unfollowed) are dropped.
        let meds = groups.flatMap(\.medications)
        let stillPending = Set(pendingDoseKeys(medications: meds, logs: logs, now: now))
        // Every dose still on yesterday's or today's plan, taken or not. A delivered reminder for
        // anything else belongs to a time that moved (a meal re-plan, a manual move) and is cleared.
        let planned = Set(doseKeys(medications: meds, logs: logs, now: now, pendingOnly: false))
        // Rebuilds run one after another, so a slower earlier one can't re-add a moved dose's old reminder.
        let previous = rescheduleTask
        rescheduleTask = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            let stale = delivered.filter { id in
                guard let key = ["dose-", "prefast-"].first(where: { id.hasPrefix($0) }).map({ String(id.dropFirst($0.count)) }) else { return false }
                return !planned.contains(key)
            }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            let pending = await center.pendingNotificationRequests()
            var ids = pending.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
            ids += pending.map(\.identifier).filter { id in
                id.hasPrefix(snoozePrefix) && !stillPending.contains(String(id.dropFirst(snoozePrefix.count)))
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            let removed = Set(ids)
            // Other pending requests (kept snoozes) share the 60.
            let others = pending.filter { !removed.contains($0.identifier) }.count
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else { return }
            for request in requests.prefix(max(0, maxRequests - others)) {
                try? await center.add(request)
            }
        }
    }

    /// Pending count and the next one's time, for the hidden debug info.
    static func pendingSummary() async -> (count: Int, next: Date?) {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let next = pending.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            ?? ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }.min()
        return (pending.count, next)
    }

    private static var rescheduleTask: Task<Void, Never>?

    /// "<medID>-<stamp>" for each pending dose from yesterday to today.
    private static func pendingDoseKeys(medications: [Medication], logs: [DoseLog], now: Date) -> [String] {
        doseKeys(medications: medications, logs: logs, now: now, pendingOnly: true)
    }

    private static func doseKeys(medications: [Medication], logs: [DoseLog], now: Date, pendingOnly: Bool) -> [String] {
        let cal = PregnancyMath.calendar
        return [-1, 0].flatMap { offset -> [String] in
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { return [] }
            return MedsEngine.instances(on: day, medications: medications, logs: logs)
                .filter { !pendingOnly || $0.isPending }
                .map { "\($0.medication.id.uuidString)-\(Int($0.scheduledAt.timeIntervalSince1970))" }
        }
    }

    private static func buildRequests(group: Group, logs: [DoseLog], now: Date) -> [(date: Date, request: UNNotificationRequest)] {
        var items: [(date: Date, request: UNNotificationRequest)] = []
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: now)
        let medications = group.medications
        let person = group.person
        let ownerTag = person.map { "-\($0.lowercased().filter(\.isLetter))" } ?? ""

        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let instances = MedsEngine.instances(on: day, medications: medications, logs: logs)

            for instance in instances where instance.isPending {
                let med = instance.medication
                let stamp = Int(instance.scheduledAt.timeIntervalSince1970)

                if instance.scheduledAt > now {
                    let content = UNMutableNotificationContent()
                    content.title = person.map { "\($0): time for \(med.shortName)" } ?? "Time for \(med.shortName)"
                    var body = med.dose.isEmpty ? "" : med.dose
                    switch med.foodRule {
                    case .emptyStomach where med.noFoodAfterMinutes > 0:
                        body += (body.isEmpty ? "" : " · ") + "Then no food for \(Medication.durationText(med.noFoodAfterMinutes))"
                    case .withFood:
                        body += (body.isEmpty ? "" : " · ") + "Take with food"
                    default: break
                    }
                    content.body = body.isEmpty ? "Tap to log it in Carry." : body
                    content.sound = .default
                    content.categoryIdentifier = doseCategory
                    content.userInfo = ["medID": med.id.uuidString, "scheduledAt": instance.scheduledAt.timeIntervalSince1970]
                    items.append((instance.scheduledAt, request(id: "dose-\(med.id.uuidString)-\(stamp)", content: content, date: instance.scheduledAt)))
                }

                if med.foodRule == .emptyStomach, med.noFoodBeforeMinutes > 0 {
                    let pauseAt = instance.scheduledAt.addingTimeInterval(-Double(med.noFoodBeforeMinutes) * 60)
                    if pauseAt > now {
                        let content = UNMutableNotificationContent()
                        if let person {
                            content.title = "\(person): snack pause"
                            content.body = "\(med.shortName) in \(Medication.durationText(med.noFoodBeforeMinutes)). Time for \(person) to finish eating."
                        } else {
                            content.title = "Snack pause"
                            content.body = "\(med.shortName) in \(Medication.durationText(med.noFoodBeforeMinutes)). Finish eating now so your tummy is empty."
                        }
                        content.sound = .default
                        content.userInfo = ["link": "carry://meds"]
                        items.append((pauseAt, request(id: "prefast-\(med.id.uuidString)-\(stamp)", content: content, date: pauseAt)))
                    }
                }
            }

            // "Can eat again" once a confirmed (taken) window ends today, per person.
            if offset == 0 {
                for window in MedsEngine.noFoodWindows(for: MedsEngine.carryOver(into: day, medications: medications, logs: logs) + instances) where window.isConfirmed && window.part != .before && window.end > now {
                    let content = UNMutableNotificationContent()
                    let reasons = window.reasons.joined(separator: " & ")
                    if let person {
                        content.title = "\(person) can eat again"
                        content.body = "The no-food window for \(reasons) is over."
                    } else {
                        content.title = "You can eat again"
                        content.body = "Your no-food window for \(reasons) is over."
                    }
                    content.sound = .default
                    content.interruptionLevel = .timeSensitive
                    content.userInfo = ["link": "carry://meds"]
                    items.append((window.end, request(id: "foodok\(ownerTag)-\(Int(window.end.timeIntervalSince1970))", content: content, date: window.end)))
                }
            }
        }
        return items
    }

    /// Right away, when a dose logged outside the app (Live Activity, widget, notification action)
    /// starts a no-food window. Its prefix is not cleared by `reschedule`. A tap opens the countdown card.
    static func postNoFoodStarted(_ alert: NoFoodAlert) {
        let content = UNMutableNotificationContent()
        content.title = "No food until \(alert.end.formatted(date: .omitted, time: .shortened))"
        content.body = "\(spokenDuration(alert.minutes)) after \(alert.namesText). Water is fine."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["link": "carry://nofood"]
        let request = UNNotificationRequest(identifier: "nofood-now-\(Int(alert.end.timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// "Eaten" was pressed on the Live Activity while food has to wait. Tapping opens the meal guard.
    static func postMealGuard(_ alert: NoFoodAlert, mealName: String, owner: MedOwner, kind: MealKind) {
        let content = UNMutableNotificationContent()
        content.title = "No food until \(alert.end.formatted(date: .omitted, time: .shortened)) (\(alert.namesText))"
        content.body = "\(mealName) wasn't logged. Log \(mealName.lowercased()) anyway?"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["link": "carry://mealguard?owner=\(owner.rawValue)&meal=\(kind.rawValue)"]
        let request = UNNotificationRequest(identifier: "mealguard-\(owner.rawValue)-\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// "30 minutes", "1 minute", "1 h 30 min".
    static func spokenDuration(_ minutes: Int) -> String {
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return Medication.durationText(minutes)
    }

    private static func request(id: String, content: UNNotificationContent, date: Date) -> UNNotificationRequest {
        let comps = PregnancyMath.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}

/// Shows reminders while Carry is open and handles the "Taken" and "Snooze" actions.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    /// Set in `CarryApp.init`. A "Taken" press that arrives before it is set waits in `pendingTaken`.
    weak var store: AppStore? {
        didSet { flushPendingTaken() }
    }

    private struct PendingTaken {
        var medicationID: UUID
        var scheduledAt: Date
        var takenAt: Date
    }
    private var pendingTaken: [PendingTaken] = []

    /// Logs the dose now, or queues it until the store exists (cold launch from the action).
    private func applyTaken(_ item: PendingTaken) {
        pendingTaken.append(item)
        flushPendingTaken()
    }

    private func flushPendingTaken() {
        guard let store, !pendingTaken.isEmpty else { return }
        let items = pendingTaken
        pendingTaken.removeAll()
        // The widget may have changed the file while Carry was suspended.
        store.reloadIfChangedExternally()
        for item in items {
            store.markTaken(medicationID: item.medicationID, scheduledAt: item.scheduledAt, at: item.takenAt)
        }
    }

    // Completion-handler versions on purpose: the async versions finish on a background
    // thread, and iOS aborts when the system completion runs off the main thread
    // (build 20 crash on a cold launch from a notification tap). Every completion
    // below is called on the main thread, exactly once.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A push from the partner's phone means shared data changed.
        let isPush = notification.request.trigger is UNPushNotificationTrigger
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isPush { SyncEngine.shared.requestPull() }
            }
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let info = content.userInfo
        let link = info["link"] as? String
        let type = info["type"] as? String
        let medIDString = info["medID"] as? String
        let hasMed = info["medID"] != nil
        let stamp = info["scheduledAt"] as? Double
        // The action is pressed when the dose is taken, so the real time is now.
        let takenAt = Date.now

        if action == MedNotifications.snoozeAction {
            Task { @MainActor in
                await MedNotifications.snooze(content)
                completionHandler()
            }
            return
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if action == UNNotificationDefaultActionIdentifier {
                    // A plain tap: partner pushes carry a `link` (carry://meds) or a dose `type`.
                    var routed: [AnyHashable: Any] = [:]
                    if let link { routed["link"] = link }
                    if let type { routed["type"] = type }
                    if hasMed { routed["medID"] = "1" }
                    DeepLinkRouter.shared.handleNotification(routed)
                } else if action == MedNotifications.takenAction,
                          let medIDString, let medID = UUID(uuidString: medIDString),
                          let stamp {
                    NotificationRouter.shared.applyTaken(PendingTaken(
                        medicationID: medID,
                        scheduledAt: Date(timeIntervalSince1970: stamp),
                        takenAt: takenAt
                    ))
                }
            }
            completionHandler()
        }
    }
}
