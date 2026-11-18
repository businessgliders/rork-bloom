import Foundation
import AppIntents
import WidgetKit

/// "Eaten" on the Live Activity. Runs in the app's process (LiveActivityIntent), so the meal log,
/// the re-plan, sync and the Live Activity update together, even with the app closed.
/// During a running no-food window it logs nothing: the app asks first ("Log breakfast anyway?").
nonisolated struct MarkMealEatenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark meal eaten"
    static let description = IntentDescription("Logs a Carry meal as eaten right now.")
    static let isDiscoverable = false

    /// "mom" or "partner": whose routine the meal belongs to.
    @Parameter(title: "Person")
    var role: String

    /// "breakfast", "lunch", "dinner" or "snack".
    @Parameter(title: "Meal")
    var meal: String

    init() {}

    init(role: String, meal: String) {
        self.role = role
        self.meal = meal
    }

    func perform() async throws -> some IntentResult {
        let eatenAt = Date.now
        #if WIDGET_EXTENSION
        // Only if the system ever runs it outside the app: the app logs it on its next wake.
        PendingMealTaps.add(role: role, meal: meal, at: eatenAt)
        AppGroup.postStateChanged()
        WidgetCenter.shared.reloadAllTimelines()
        #else
        guard let owner = MedOwner(rawValue: role), let kind = MealKind(rawValue: meal) else { return .result() }
        await MainActor.run {
            let store = AppStore.shared
            store.reloadIfChangedExternally()
            store.eatenFromLiveActivity(owner: owner, kind: kind, at: eatenAt)
        }
        // Keep the process alive until the log reaches the server, so the other phone's card moves on.
        await SyncEngine.shared.flush()
        #endif
        return .result()
    }
}

/// Meal taps waiting for the app (App Group defaults), "role|meal|unixSeconds".
nonisolated enum PendingMealTaps {
    private static let key = "bloom.pendingMealTaps"

    static func add(role: String, meal: String, at date: Date) {
        let defaults = UserDefaults(suiteName: AppGroup.id)
        var list = defaults?.stringArray(forKey: key) ?? []
        list.append("\(role)|\(meal)|\(Int(date.timeIntervalSince1970))")
        defaults?.set(list, forKey: key)
    }

    static func take() -> [(role: String, meal: String, at: Date)] {
        let defaults = UserDefaults(suiteName: AppGroup.id)
        guard let list = defaults?.stringArray(forKey: key), !list.isEmpty else { return [] }
        defaults?.removeObject(forKey: key)
        return list.compactMap { item in
            let parts = item.split(separator: "|").map(String.init)
            guard parts.count == 3, let seconds = Double(parts[2]) else { return nil }
            return (parts[0], parts[1], Date(timeIntervalSince1970: seconds))
        }
    }
}
