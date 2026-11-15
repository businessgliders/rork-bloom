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
        let requests = groups
            .flatMap { buildRequests(group: $0, logs: logs, now: now) }
            .sorted { $0.date < $1.date }
            .prefix(maxRequests)
            .map(\.request)
        // Snoozes for doses that are no longer pending (logged, deleted, unfollowed) are dropped.
        let stillPending = Set(pendingDoseKeys(medications: groups.flatMap(\.medications), logs: logs, now: now))
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            var ids = pending.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
            ids += pending.map(\.identifier).filter { id in
                id.hasPrefix(snoozePrefix) && !stillPending.contains(String(id.dropFirst(snoozePrefix.count)))
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            for request in requests {
                try? await center.add(request)
            }
        }
    }

    /// "<medID>-<stamp>" for each pending dose from yesterday to today.
    private static func pendingDoseKeys(medications: [Medication], logs: [DoseLog], now: Date) -> [String] {
        let cal = PregnancyMath.calendar
        return [-1, 0].flatMap { offset -> [String] in
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { return [] }
            return MedsEngine.instances(on: day, medications: medications, logs: logs)
                .filter(\.isPending)
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
                    content.title = person.map { "\(med.emoji) \($0): time for \(med.shortName)" } ?? "\(med.emoji) Time for \(med.shortName)"
                    var body = med.dose.isEmpty ? "" : med.dose
                    switch med.foodRule {
                    case .emptyStomach where med.noFoodAfterMinutes > 0:
                        body += (body.isEmpty ? "" : " · ") + "Then no food for \(Medication.durationText(med.noFoodAfterMinutes))"
                    case .withFood:
                        body += (body.isEmpty ? "" : " · ") + "Take with food"
                    default: break
                    }
                    content.body = body.isEmpty ? "Tap to log it in Bloom." : body
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
                            content.title = "\(person): snack pause 🍓"
                            content.body = "\(med.shortName) in \(Medication.durationText(med.noFoodBeforeMinutes)). Time for \(person) to finish eating."
                        } else {
                            content.title = "Snack pause 🍓"
                            content.body = "\(med.shortName) in \(Medication.durationText(med.noFoodBeforeMinutes)). Finish eating now so your tummy is empty."
                        }
                        content.sound = .default
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
                        content.title = "\(person) can eat again 🍽️"
                        content.body = "The no-food window for \(reasons) is over."
                    } else {
                        content.title = "You can eat again 🍽️"
                        content.body = "Your no-food window for \(reasons) is over. Enjoy!"
                    }
                    content.sound = .default
                    items.append((window.end, request(id: "foodok\(ownerTag)-\(Int(window.end.timeIntervalSince1970))", content: content, date: window.end)))
                }
            }
        }
        return items
    }

    private static func request(id: String, content: UNNotificationContent, date: Date) -> UNNotificationRequest {
        let comps = PregnancyMath.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}

/// Shows reminders while Bloom is open and handles the "Taken" and "Snooze" actions.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    weak var store: AppStore?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A push from the partner's phone means shared data changed.
        if notification.request.trigger is UNPushNotificationTrigger {
            await MainActor.run { SyncEngine.shared.requestPull() }
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if response.actionIdentifier == MedNotifications.snoozeAction {
            await MedNotifications.snooze(content)
            return
        }
        guard response.actionIdentifier == MedNotifications.takenAction else { return }
        let info = content.userInfo
        guard let idString = info["medID"] as? String,
              let medID = UUID(uuidString: idString),
              let stamp = info["scheduledAt"] as? Double else { return }
        // The action is pressed when the dose is taken, so the real time is now.
        let takenAt = Date.now
        await MainActor.run {
            // The widget may have changed the file while Bloom was suspended.
            NotificationRouter.shared.store?.reloadIfChangedExternally()
            NotificationRouter.shared.store?.markTaken(
                medicationID: medID,
                scheduledAt: Date(timeIntervalSince1970: stamp),
                at: takenAt
            )
        }
    }
}
