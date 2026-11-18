import SwiftUI

/// Hidden debug info (long-press the version footer in Settings).
struct SyncDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncEngine.self) private var sync
    @State private var permission = NotificationPermission.shared
    @State private var pendingCount: Int?
    @State private var nextAt: Date?
    @State private var tick = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Notifications") {
                    row("Permission", permission.statusText)
                    row("Pending", pendingCount.map(String.init) ?? "\u{2026}")
                    row("Next", nextAt.map(Self.format) ?? "none")
                }
                Section("Realtime") {
                    row("Channel", sync.realtimeStatus)
                    row("Last event", sync.lastRealtimeEvent.map(Self.format) ?? "none yet")
                    row("Last pull", sync.lastPullAt.map(Self.format) ?? "none yet")
                }
                Section("Live Activity") {
                    row("Update token", PushRegistry.shared.updateTokenSummary)
                    row("Last upload error", PushRegistry.shared.lastUploadError.map { error in
                        PushRegistry.shared.lastUploadErrorAt.map { "\(Self.format($0)) \u{00B7} \(error)" } ?? error
                    } ?? "none")
                    row("Retry on foreground", PushRegistry.shared.needsRetry ? "yes" : "no")
                    row("APNs environment", APNsEnvironment.current.rawValue)
                }
            }
            .id(tick)
            .font(.system(size: 14))
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Refresh") { Task { await load() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        await permission.refresh(offerPrompt: false)
        let summary = await MedNotifications.pendingSummary()
        pendingCount = summary.count
        nextAt = summary.next
        tick += 1
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}
