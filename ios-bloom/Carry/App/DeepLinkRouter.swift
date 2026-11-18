import SwiftUI

/// Routes `carry://` links (widgets, Live Activity, notification taps) to the right screen.
/// A request is a counter so the same link twice still fires, and it waits until the
/// tab view exists when the app is cold-launched from a link.
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    enum Destination: Equatable { case meds }

    /// Bumped on every request; views react with `onChange`.
    private(set) var medsRequest = 0
    /// Set until the Meds tab has handled the request (survives a cold launch).
    var pendingMeds = false
    /// Whose day the request is about (her alert, your reminder); Meds today switches to them.
    var pendingOwner: MedOwner?

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "carry" || url.scheme?.lowercased() == "bloom" else { return false }
        let target = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let person = Self.owner(from: Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } },
                                                   uniquingKeysWith: { first, _ in first })) {
            pendingOwner = person
        }
        switch target {
        case "meds", "dose":
            openMeds()
            return true
        case "nofood":
            // The "No food until" notification: Meds, with the countdown card while the window runs.
            openMeds()
            AppStore.shared.showNoFoodAlertIfActive()
            return true
        case "mealguard":
            // "Eaten" during a no-food window: Meds today with "Log breakfast anyway?" on that meal.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value?.lowercased() }
            let store = AppStore.shared
            if let owner = value("owner").flatMap(MedOwner.init(rawValue:)),
               let kind = value("meal").flatMap(MealKind.init(rawValue:)),
               store.pendingMealGuard?.owner != owner || store.pendingMealGuard?.kind != kind {
                store.pendingMealGuard = MealGuardRequest(owner: owner, kind: kind)
            }
            openMeds()
            return true
        case "dailynote", "note":
            DailyNoteCenter.shared.openFromNotification()
            return true
#if DEBUG
        case "debug-note":
            // Simulator testing: carry://debug-note (first open, types) or carry://debug-note?again=1.
            DailyNoteCenter.shared.debugInsert(fresh: url.query?.contains("again") != true)
            return true
#endif
        default:
            return false
        }
    }

    func openMeds() {
        pendingMeds = true
        medsRequest += 1
    }

    /// Whose day a link or payload is about: `owner` (mom / partner), else `taker_id` (a member's
    /// user id), else the medication's taker (`medication_id` or a local reminder's `medID`).
    static func owner(from info: [String: String]) -> MedOwner? {
        if let raw = info["owner"]?.lowercased(), let owner = MedOwner(rawValue: raw) { return owner }
        let store = AppStore.shared
        if let id = info["taker_id"].flatMap(UUID.init(uuidString:)), let owner = store.role(of: id) { return owner }
        for key in ["medication_id", "medID"] {
            if let id = info[key].flatMap(UUID.init(uuidString:)),
               let med = store.medications.first(where: { $0.id == id }) {
                return med.owner
            }
        }
        return nil
    }

    /// Notification payloads: a `link` wins, else any dose-related `type` (or a local dose reminder).
    func handleNotification(_ info: [AnyHashable: Any]) {
        if let type = (info["type"] as? String)?.lowercased(), type == "daily_note" {
            DailyNoteCenter.shared.openFromNotification()
            return
        }
        var keys: [String: String] = [:]
        for key in ["owner", "taker_id", "medication_id", "medID"] {
            if let value = info[key] as? String { keys[key] = value }
        }
        if let person = Self.owner(from: keys) { pendingOwner = person }
        if let link = info["link"] as? String, let url = URL(string: link), handle(url) { return }
        if let type = (info["type"] as? String)?.lowercased(), type.hasPrefix("dose") || type.contains("dose") {
            openMeds(); return
        }
        if info["medID"] != nil { openMeds() }
    }
}
