import Foundation
import EventKit
import UIKit

/// Two-way mirror between Carry doses and a "Carry Meds" list in Apple Reminders.
///
/// - Covers doses from yesterday through tomorrow; older/newer reminders are tidied away.
/// - Reminders carry no alarms: Carry's own notifications already ping.
/// - Conflicts: if both sides changed since the last sync, Carry wins.
final class RemindersSync {
    static let shared = RemindersSync()

    static let listTitle = "Carry Meds"
    /// The list's name before the app was renamed; renamed in place when found.
    static let oldListTitle = "Bloom Meds"
    private let eventStore = EKEventStore()
    private var isSyncing = false
    private var pendingResync = false
    private var observer: NSObjectProtocol?

    /// Per dose key, the state both sides had at the last sync ("<bloomDone>|<reminderDone>").
    private let stateKey = "bloom.reminders.lastSynced"
    /// Per dose key, the reminder's calendarItemIdentifier (fallback if the URL isn't kept).
    private let idsKey = "bloom.reminders.itemIDs"

    private var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Edits made in the Reminders app while Carry is running.
    func observeExternalChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { _ in
            Task { @MainActor in
                RemindersSync.shared.eventStore.refreshSourcesIfNecessary()
                RemindersSync.shared.sync(store: AppStore.shared)
            }
        }
    }

    func sync(store: AppStore) {
        guard store.remindersSyncEnabled, authorized else { return }
        if isSyncing {
            pendingResync = true
            return
        }
        isSyncing = true
        Task {
            await performSync(store: store)
            isSyncing = false
            if pendingResync {
                pendingResync = false
                sync(store: store)
            }
        }
    }

    /// Deletes the Carry Meds list (when sync is turned off or all data is deleted).
    func removeList(id: String?) {
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: idsKey)
        guard authorized else { return }
        let calendar = id.flatMap { eventStore.calendar(withIdentifier: $0) }
            ?? eventStore.calendars(for: .reminder).first { ($0.title == Self.listTitle || $0.title == Self.oldListTitle) && $0.allowsContentModifications }
        guard let calendar else { return }
        try? eventStore.removeCalendar(calendar, commit: true)
    }

    // MARK: - Sync

    private func performSync(store: AppStore) async {
        guard let calendar = list(for: store) else { return }

        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: .now)
        var instances: [String: DoseInstance] = [:]
        for offset in -1...1 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            for instance in store.liveInstances(on: day) {
                instances[Self.key(instance.medication.id, instance.scheduledAt)] = instance
            }
        }

        let reminders = await fetchReminders(in: calendar)
        var lastSynced = UserDefaults.standard.dictionary(forKey: stateKey) as? [String: String] ?? [:]
        var itemIDs = UserDefaults.standard.dictionary(forKey: idsKey) as? [String: String] ?? [:]
        let keyByItemID = Dictionary(itemIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })

        var byKey: [String: EKReminder] = [:]
        var strays: [EKReminder] = []
        for reminder in reminders {
            if let key = Self.key(from: reminder.url) ?? keyByItemID[reminder.calendarItemIdentifier] {
                if byKey[key] == nil { byKey[key] = reminder } else { strays.append(reminder) }
            }
        }

        var taken: [(medicationID: UUID, scheduledAt: Date, takenAt: Date)] = []
        var cleared: [(medicationID: UUID, scheduledAt: Date)] = []
        var dirty = false

        for (key, instance) in instances {
            let bloomDone = !instance.isPending
            if let reminder = byKey[key] {
                let remDone = reminder.isCompleted
                let last = lastSynced[key].map(Self.parse)
                let bloomChanged = last == nil || last!.bloom != bloomDone
                let remChanged = last != nil && last!.reminder != remDone

                if bloomChanged {
                    // Carry is the source of truth when it changed (and when both did).
                    if remDone != bloomDone || reminder.title != Self.title(for: instance) {
                        apply(instance, to: reminder)
                        try? eventStore.save(reminder, commit: false)
                        dirty = true
                    }
                    lastSynced[key] = Self.format(bloom: bloomDone, reminder: bloomDone)
                } else if remChanged {
                    if remDone, instance.isPending {
                        taken.append((instance.medication.id, instance.scheduledAt, reminder.completionDate ?? .now))
                    } else if !remDone, !instance.isPending {
                        cleared.append((instance.medication.id, instance.scheduledAt))
                    }
                    lastSynced[key] = Self.format(bloom: remDone, reminder: remDone)
                } else if reminder.title != Self.title(for: instance) {
                    reminder.title = Self.title(for: instance)
                    try? eventStore.save(reminder, commit: false)
                    dirty = true
                }
                itemIDs[key] = reminder.calendarItemIdentifier
            } else {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                apply(instance, to: reminder)
                if (try? eventStore.save(reminder, commit: false)) != nil {
                    dirty = true
                    lastSynced[key] = Self.format(bloom: bloomDone, reminder: bloomDone)
                    itemIDs[key] = reminder.calendarItemIdentifier
                }
            }
        }

        // Tidy: doses outside the window, deleted medications, duplicates.
        for (key, reminder) in byKey where instances[key] == nil {
            try? eventStore.remove(reminder, commit: false)
            lastSynced[key] = nil
            itemIDs[key] = nil
            dirty = true
        }
        for reminder in strays {
            try? eventStore.remove(reminder, commit: false)
            dirty = true
        }
        for key in Array(lastSynced.keys) where instances[key] == nil { lastSynced[key] = nil }
        for key in Array(itemIDs.keys) where instances[key] == nil { itemIDs[key] = nil }

        if dirty { try? eventStore.commit() }
        UserDefaults.standard.set(lastSynced, forKey: stateKey)
        UserDefaults.standard.set(itemIDs, forKey: idsKey)

        store.applyReminderChanges(taken: taken, cleared: cleared)
    }

    private func apply(_ instance: DoseInstance, to reminder: EKReminder) {
        let med = instance.medication
        reminder.title = Self.title(for: instance)
        var notes: [String] = []
        if !med.dose.trimmingCharacters(in: .whitespaces).isEmpty { notes.append(med.dose) }
        if med.foodRule != .any { notes.append(med.foodSummary) }
        notes.append("From Carry")
        reminder.notes = notes.joined(separator: "\n")
        reminder.url = URL(string: "bloom://dose/\(med.id.uuidString)/\(Int(instance.scheduledAt.timeIntervalSince1970))")
        var comps = PregnancyMath.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instance.scheduledAt)
        comps.timeZone = .current
        reminder.dueDateComponents = comps
        reminder.alarms = nil
        reminder.isCompleted = !instance.isPending
        if instance.isPending {
            reminder.completionDate = nil
        } else {
            reminder.completionDate = instance.log?.takenAt ?? instance.log?.loggedAt ?? .now
        }
    }

    private func renameIfOld(_ calendar: EKCalendar) {
        guard calendar.title == Self.oldListTitle, calendar.allowsContentModifications else { return }
        calendar.title = Self.listTitle
        try? eventStore.saveCalendar(calendar, commit: true)
    }

    private func list(for store: AppStore) -> EKCalendar? {
        if let id = store.remindersListID, let existing = eventStore.calendar(withIdentifier: id) {
            renameIfOld(existing)
            return existing
        }
        if let existing = eventStore.calendars(for: .reminder).first(where: { ($0.title == Self.listTitle || $0.title == Self.oldListTitle) && $0.allowsContentModifications }) {
            renameIfOld(existing)
            store.setRemindersListID(existing.calendarIdentifier)
            return existing
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = Self.listTitle
        calendar.cgColor = UIColor(hex: 0xEE9AA6).cgColor
        guard let source = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .local }) else { return nil }
        calendar.source = source
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            store.setRemindersListID(calendar.calendarIdentifier)
            return calendar
        } catch {
            return nil
        }
    }

    private func fetchReminders(in calendar: EKCalendar) async -> [EKReminder] {
        let predicate = eventStore.predicateForReminders(in: [calendar])
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Keys

    static func key(_ medicationID: UUID, _ scheduledAt: Date) -> String {
        "\(medicationID.uuidString)/\(Int(scheduledAt.timeIntervalSince1970))"
    }

    static func key(from url: URL?) -> String? {
        guard let url, url.scheme == "bloom", url.host == "dose" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, UUID(uuidString: parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    static func title(for instance: DoseInstance) -> String {
        "\(instance.medication.emoji) \(instance.medication.shortName)"
    }

    private static func format(bloom: Bool, reminder: Bool) -> String { "\(bloom ? 1 : 0)|\(reminder ? 1 : 0)" }

    private static func parse(_ value: String) -> (bloom: Bool, reminder: Bool) {
        let parts = value.split(separator: "|")
        return (parts.first == "1", parts.last == "1")
    }
}
