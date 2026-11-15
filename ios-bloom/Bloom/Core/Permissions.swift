import EventKit
import UserNotifications

enum Permissions {
    static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestReminders() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    static var remindersGranted: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }
}
