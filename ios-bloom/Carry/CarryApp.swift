import SwiftUI
import UserNotifications

/// Registers for remote notifications (partner alerts, sync nudges) and hands tokens to `PushRegistry`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistry.shared.setAPNsToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        SyncEngine.shared.requestPull(immediately: true)
        return .newData
    }
}

@main
struct CarryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var sync = SyncEngine.shared

    init() {
        let store = AppStore.shared
        _store = State(initialValue: store)
        NotificationRouter.shared.store = store
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        MedNotifications.registerCategories()
        Self.observeSharedStateChanges()
        RemindersSync.shared.observeExternalChanges()
        SyncEngine.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                .tint(Theme.blushDeep)
                .preferredColorScheme(store.appearance.colorScheme)
        }
    }

    /// The widget extension posts this after writing the shared file.
    private static func observeSharedStateChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    AppStore.shared.reloadIfChangedExternally()
                    AppStore.shared.refreshReminders()
                }
            },
            AppGroup.stateChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
}
