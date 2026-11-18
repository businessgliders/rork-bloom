import SwiftUI
import UserNotifications

/// The notification permission, checked on every foreground. Dose reminders are local,
/// so without permission nothing reaches her. Covers every way into the app, including the
/// welcome + sign-in flow that skips the old onboarding permission step.
@MainActor
@Observable
final class NotificationPermission {
    static let shared = NotificationPermission()

    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var checked = false
    /// The pre-prompt sheet ("Get a nudge…").
    var showPrePrompt = false
    /// Bumped when the "Notifications are off" banner is dismissed, so views re-read it.
    private(set) var bannerDismissedAt: Date?

    private static let prePromptKey = "notif.prePromptDismissedAt"
    private static let bannerKey = "notif.bannerDismissedAt"

    private init() {
        bannerDismissedAt = UserDefaults.standard.object(forKey: Self.bannerKey) as? Date
    }

    var isOn: Bool { status == .authorized || status == .provisional || status == .ephemeral }

    var statusText: String {
        switch status {
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    /// The slim banner on Meds today: denied, and not dismissed in the last 24 h.
    var showDeniedBanner: Bool {
        guard checked, status == .denied else { return false }
        guard let bannerDismissedAt else { return true }
        return Date.now.timeIntervalSince(bannerDismissedAt) > 24 * 3600
    }

    func dismissBanner() {
        bannerDismissedAt = .now
        UserDefaults.standard.set(Date.now, forKey: Self.bannerKey)
    }

    /// Reads the status; offers the pre-prompt when undecided (at most once a day after Not now).
    /// Rebuilds reminders when it just became allowed.
    func refresh(offerPrompt: Bool) async {
        let was = isOn
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        checked = true
        if isOn && !was {
            AppStore.shared.refreshReminders()
            UIApplication.shared.registerForRemoteNotifications()
        }
        if offerPrompt, status == .notDetermined, !showPrePrompt {
            let last = UserDefaults.standard.object(forKey: Self.prePromptKey) as? Date
            if last.map({ Date.now.timeIntervalSince($0) > 24 * 3600 }) ?? true { showPrePrompt = true }
        }
    }

    func allow() async {
        showPrePrompt = false
        _ = await Permissions.requestNotifications()
        await refresh(offerPrompt: false)
    }

    func notNow() {
        showPrePrompt = false
        UserDefaults.standard.set(Date.now, forKey: Self.prePromptKey)
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Short pre-prompt before the system notification alert.
struct NotificationPrePrompt: View {
    @State private var permission = NotificationPermission.shared

    var body: some View {
        VStack(spacing: 18) {
            CarryMark(size: 52)
                .padding(.top, 28)
            VStack(spacing: 8) {
                Text("Get a nudge when it's time for each med")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.dayText)
                    .multilineTextAlignment(.center)
                Text("Reminders come from this iPhone, so Carry needs your OK to send them.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    Task { await permission.allow() }
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.rose))
                .accessibilityIdentifier("notif-preprompt-allow")
                Button {
                    permission.notNow()
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.daySecondary, fill: Theme.dayCard))
                .accessibilityIdentifier("notif-preprompt-notnow")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.dayCanvas.ignoresSafeArea())
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }
}

/// "Notifications are off · reminders won't arrive" at the top of Meds today.
struct NotificationsOffBanner: View {
    @State private var permission = NotificationPermission.shared

    var body: some View {
        if permission.showDeniedBanner {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.terraText)
                Text("Notifications are off \u{00B7} reminders won't arrive")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.terraText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Turn on") {
                    Haptics.tap()
                    NotificationPermission.openSettings()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("notif-banner-turn-on")
                Button {
                    withAnimation(.snappy) { permission.dismissBanner() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.terraText.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss for a day")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .background(Theme.terraTint, in: .rect(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
        }
    }
}
