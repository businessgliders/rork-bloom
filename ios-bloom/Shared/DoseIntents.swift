import Foundation
import AppIntents
import WidgetKit

/// "Taken" from a widget or the Live Activity. As a LiveActivityIntent it runs in the app's process,
/// so the store, notifications, Live Activity and Reminders all update together.
/// If it ever runs inside the widget extension, it edits the shared file directly.
nonisolated struct MarkDoseTakenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark dose taken"
    static let description = IntentDescription("Logs a Carry dose as taken right now.")
    static let isDiscoverable = false

    @Parameter(title: "Medication ID")
    var medID: String

    @Parameter(title: "Scheduled time")
    var scheduledAt: Double

    init() {}

    init(medID: String, scheduledAt: Date) {
        self.medID = medID
        self.scheduledAt = scheduledAt.timeIntervalSince1970
    }

    func perform() async throws -> some IntentResult {
        // Pressed when the dose is taken, so food windows count from now.
        let takenAt = Date.now
        guard let medicationID = UUID(uuidString: medID) else { return .result() }
        let scheduled = Date(timeIntervalSince1970: scheduledAt)

        #if WIDGET_EXTENSION
        if SharedStateFile.markTaken(medicationID: medicationID, scheduledAt: scheduled, takenAt: takenAt) {
            AppGroup.postStateChanged()
        }
        WidgetCenter.shared.reloadAllTimelines()
        #else
        await MainActor.run {
            let store = AppStore.shared
            store.reloadIfChangedExternally()
            store.markTaken(medicationID: medicationID, scheduledAt: scheduled, at: takenAt)
        }
        #endif
        return .result()
    }
}
