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

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "carry" || url.scheme?.lowercased() == "bloom" else { return false }
        let target = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        switch target {
        case "meds", "dose":
            openMeds()
            return true
        case "nofood":
            // The "No food until" notification: Meds, with the countdown card while the window runs.
            openMeds()
            AppStore.shared.showNoFoodAlertIfActive()
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

    /// Notification payloads: a `link` wins, else any dose-related `type` (or a local dose reminder).
    func handleNotification(_ info: [AnyHashable: Any]) {
        if let type = (info["type"] as? String)?.lowercased(), type == "daily_note" {
            DailyNoteCenter.shared.openFromNotification()
            return
        }
        if let link = info["link"] as? String, let url = URL(string: link), handle(url) { return }
        if let type = (info["type"] as? String)?.lowercased(), type.hasPrefix("dose") || type.contains("dose") {
            openMeds(); return
        }
        if info["medID"] != nil { openMeds() }
    }
}
