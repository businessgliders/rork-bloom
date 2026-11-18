import Foundation
import Observation
import Supabase

/// Yesterday's meds, as the server summarised them for the note.
nonisolated struct DailyNoteRecap: Equatable, Sendable {
    enum Status: String, Sendable { case onTime = "on_time", late, early, missed, skipped, other }
    var items: [Status]
    var taken: Int
    var total: Int

    /// Tolerant reader: an array of items (or `{items|doses: [...]}`), each a status string or an object
    /// with `status`. `taken` / `total` win when the server sends them.
    init?(json: AnyJSON?) {
        guard let json else { return nil }
        var list: [AnyJSON] = []
        var takenOverride: Int?
        var totalOverride: Int?
        switch json {
        case .array(let a):
            list = a
        case .object(let o):
            for key in ["items", "doses", "meds"] {
                if case .array(let a)? = o[key] { list = a; break }
            }
            takenOverride = o["taken"].flatMap(Self.int)
            totalOverride = o["total"].flatMap(Self.int)
        default:
            return nil
        }
        items = list.compactMap { item in
            switch item {
            case .string(let s): return Status(rawValue: s.lowercased()) ?? .other
            case .object(let o):
                if case .string(let s)? = o["status"] { return Status(rawValue: s.lowercased()) ?? .other }
                return nil
            default: return nil
            }
        }
        let counted = items.filter { $0 == .onTime || $0 == .late || $0 == .early }.count
        taken = takenOverride ?? counted
        total = totalOverride ?? items.count
        if items.isEmpty && total == 0 { return nil }
    }

    init(items: [Status]) {
        self.items = items
        taken = items.filter { $0 == .onTime || $0 == .late || $0 == .early }.count
        total = items.count
    }

    private static func int(_ v: AnyJSON) -> Int? {
        switch v {
        case .integer(let i): i
        case .double(let d): Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }
}

/// One row of `daily_notes`: the server writes it (and sends the push); the app only shows it.
nonisolated struct DailyNote: Equatable, Identifiable, Sendable {
    var id: String
    var noteDate: String
    var title: String
    var body: String
    var recap: DailyNoteRecap?
    var week: Int?
}

nonisolated struct RemoteDailyNoteRow: Decodable, Sendable {
    var id: String?
    var note_date: String
    var title: String?
    var body: String?
    var push_text: String?
    var recap: AnyJSON?
    var source: String?
    var week: Int?

    var note: DailyNote {
        DailyNote(id: id ?? note_date, noteDate: note_date,
                  title: (title?.isEmpty == false ? title : nil) ?? "Good morning",
                  body: body ?? push_text ?? "",
                  recap: DailyNoteRecap(json: recap), week: week)
    }
}

/// Today's note: fetched on foreground and on every pull, shown once a day as a popup over Meds today
/// or Journey, and reopened from the "Note" pill.
@Observable
final class DailyNoteCenter {
    static let shared = DailyNoteCenter()

    struct Presentation: Identifiable, Equatable {
        let id = UUID()
        var note: DailyNote
        var animate: Bool
    }

    /// Today's note, when the server has written one.
    private(set) var note: DailyNote?
    /// The popup on screen (RootView draws it after the no-food card).
    var presentation: Presentation?

    /// RootView: onboarded, splash gone, no sync prompt.
    var rootReady = false { didSet { if rootReady { considerShowing() } } }
    /// Meds today or Journey on screen.
    private var homeScreens: Set<String> = []
    /// Set on each foreground; cleared once that foreground has shown (or ruled out) the popup.
    private var foregroundPending = false
    /// A "daily_note" notification tap waiting for the note or the screen.
    private var notificationPending = false
    private var fetchTask: Task<Void, Never>?

    private static let shownKey = "carry.dailyNote.shownDate"

    private init() {}

    private var today: String { SyncFormat.day(.now) }
    var todaysNote: DailyNote? { note?.noteDate == today ? note : nil }

    private var shownToday: Bool { UserDefaults.standard.string(forKey: Self.shownKey) == today }
    private func markShown() { UserDefaults.standard.set(today, forKey: Self.shownKey) }

    // MARK: Screens

    func homeAppeared(_ id: String) {
        homeScreens.insert(id)
        considerShowing()
    }

    func homeDisappeared(_ id: String) { homeScreens.remove(id) }

    // MARK: Triggers

    /// scenePhase .active (and cold launch): fetch, then show it if it is the first time today.
    func didBecomeActive() {
        foregroundPending = true
        fetch()
    }

    /// A tap on a notification with type "daily_note": always opens it.
    func openFromNotification() {
        notificationPending = true
        DeepLinkRouter.shared.openMeds()
        if todaysNote != nil { considerShowing() }
        fetch()
    }

    /// The "Note" pill: the whole note at once.
    func reopen() {
        guard let note = todaysNote else { return }
        presentation = Presentation(note: note, animate: false)
    }

    func close() { presentation = nil }

    // MARK: Data

    func fetch() {
        guard let uid = SyncEngine.shared.userID else {
            foregroundPending = false
            return
        }
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            let day = SyncFormat.day(.now)
            let rows: [RemoteDailyNoteRow]? = try? await Backend.client.from("daily_notes")
                .select("id, note_date, title, body, push_text, recap, source, week")
                .eq("user_id", value: uid)
                .eq("note_date", value: day)
                .limit(1)
                .execute().value
            guard !Task.isCancelled else { return }
            if let rows { self.apply(rows.first?.note) }
            self.considerShowing()
            // Nothing there yet: this foreground is done; the next one checks again.
            if self.todaysNote == nil { self.foregroundPending = false }
        }
    }

    /// From a pull (or the fetch above). A note arriving while the app is open waits for the next foreground.
    func apply(_ newNote: DailyNote?) {
        if let newNote, newNote.noteDate == today {
            note = newNote
            if var p = presentation, p.note.id == newNote.id { p.note = newNote; presentation = p }
            if notificationPending { considerShowing() }
        } else if newNote == nil, note?.noteDate != today {
            note = nil
        }
    }

    func signedOut() {
        note = nil
        presentation = nil
        foregroundPending = false
        notificationPending = false
    }

    private func considerShowing() {
        guard rootReady, !homeScreens.isEmpty, presentation == nil else { return }
        guard let note = todaysNote else { return }
        if notificationPending {
            notificationPending = false
            foregroundPending = false
            let first = !shownToday
            markShown()
            presentation = Presentation(note: note, animate: first)
        } else if foregroundPending {
            foregroundPending = false
            guard !shownToday else { return }
            markShown()
            presentation = Presentation(note: note, animate: true)
        }
    }

#if DEBUG
    /// Simulator testing only (carry://debug-note): a sample note as if the server had written it.
    func debugInsert(fresh: Bool) {
        if fresh { UserDefaults.standard.removeObject(forKey: Self.shownKey) }
        note = DailyNote(
            id: "debug-\(today)", noteDate: today,
            title: "Good morning, Maya",
            body: "Ten weeks today. Baby is officially a fetus now, and every major organ has started its work. Yesterday you kept every dose on time but one, which is a lovely rhythm to carry into today. If the tiredness lands this afternoon, let it: a short rest counts as care too. Progesterone is first, with breakfast at eight.",
            recap: DailyNoteRecap(items: [.onTime, .onTime, .late, .missed, .skipped]),
            week: nil)
        foregroundPending = true
        considerShowing()
    }
#endif
}
