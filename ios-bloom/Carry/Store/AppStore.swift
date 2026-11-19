import SwiftUI
import UIKit
import WidgetKit

/// Light/dark override chosen in Settings.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Everything Carry persists locally. Versioned so later stages (meds, sync)
/// can extend it without losing data.
struct PersistedState: Codable {
    var version: Int = 2
    var profile: PregnancyProfile?
    var milestones: [Milestone] = []
    var onboardingComplete: Bool = false
    var disclaimerAccepted: Bool = false
    // v2 (stage 2): medications
    var medications: [Medication] = []
    var doseLogs: [DoseLog] = []
    /// nil = never asked; true/false = the user's choice about sending medication names for AI suggestions.
    var aiLookupConsent: Bool?
    // v3 (stage 3): Live Activity, Reminders sync, appearance
    var liveActivitiesEnabled: Bool = true
    var remindersSyncEnabled: Bool = false
    var remindersListID: String?
    var appearance: AppAppearance = .system
    // v4 (stage 4): account, sharing and sync queue
    var account: SyncAccount?
    var followModes: [String: FollowMode] = [:]
    var pendingOps: [SyncOp] = []
    var opSeq: Int = 0
    var partnerAlertsEnabled: Bool = true
    /// Medications this phone follows live. Widgets read it so they match the Live Activity.
    var liveMedicationIDs: [UUID]?
    // v5 (round 1): routines, timing rules and "Just today" overrides
    var templates: [ScheduleTemplate] = []
    var rules: [ScheduleRule] = []
    var overrides: [DayOverride] = []
    // v6: "Your meds & rules" exactly as typed, per person (owner raw value). Kept on this phone only.
    var medsText: [String: String] = [:]
    // v7: meals checked off on Meds today (last few days)
    var mealLogs: [MealLog] = []

    init(
        profile: PregnancyProfile?,
        milestones: [Milestone],
        onboardingComplete: Bool,
        disclaimerAccepted: Bool,
        medications: [Medication],
        doseLogs: [DoseLog],
        aiLookupConsent: Bool?,
        liveActivitiesEnabled: Bool,
        remindersSyncEnabled: Bool,
        remindersListID: String?,
        appearance: AppAppearance,
        account: SyncAccount? = nil,
        followModes: [String: FollowMode] = [:],
        pendingOps: [SyncOp] = [],
        opSeq: Int = 0,
        partnerAlertsEnabled: Bool = true,
        liveMedicationIDs: [UUID]? = nil,
        templates: [ScheduleTemplate] = [],
        rules: [ScheduleRule] = [],
        overrides: [DayOverride] = [],
        medsText: [String: String] = [:],
        mealLogs: [MealLog] = []
    ) {
        self.version = 7
        self.medsText = medsText
        self.mealLogs = mealLogs
        self.templates = templates
        self.rules = rules
        self.overrides = overrides
        self.account = account
        self.followModes = followModes
        self.pendingOps = pendingOps
        self.opSeq = opSeq
        self.partnerAlertsEnabled = partnerAlertsEnabled
        self.liveMedicationIDs = liveMedicationIDs
        self.profile = profile
        self.milestones = milestones
        self.onboardingComplete = onboardingComplete
        self.disclaimerAccepted = disclaimerAccepted
        self.medications = medications
        self.doseLogs = doseLogs
        self.aiLookupConsent = aiLookupConsent
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.remindersSyncEnabled = remindersSyncEnabled
        self.remindersListID = remindersListID
        self.appearance = appearance
    }

    /// Tolerant decoding so files saved by older versions (without meds) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profile = try c.decodeIfPresent(PregnancyProfile.self, forKey: .profile)
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        disclaimerAccepted = try c.decodeIfPresent(Bool.self, forKey: .disclaimerAccepted) ?? false
        medications = try c.decodeIfPresent([Medication].self, forKey: .medications) ?? []
        doseLogs = try c.decodeIfPresent([DoseLog].self, forKey: .doseLogs) ?? []
        aiLookupConsent = try c.decodeIfPresent(Bool.self, forKey: .aiLookupConsent)
        liveActivitiesEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveActivitiesEnabled) ?? true
        remindersSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersSyncEnabled) ?? false
        remindersListID = try c.decodeIfPresent(String.self, forKey: .remindersListID)
        appearance = (try? c.decodeIfPresent(AppAppearance.self, forKey: .appearance)) ?? .system
        account = try? c.decodeIfPresent(SyncAccount.self, forKey: .account)
        followModes = (try? c.decodeIfPresent([String: FollowMode].self, forKey: .followModes)) ?? [:]
        pendingOps = (try? c.decodeIfPresent([SyncOp].self, forKey: .pendingOps)) ?? []
        opSeq = (try? c.decodeIfPresent(Int.self, forKey: .opSeq)) ?? 0
        partnerAlertsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .partnerAlertsEnabled)) ?? true
        liveMedicationIDs = try? c.decodeIfPresent([UUID].self, forKey: .liveMedicationIDs)
        templates = (try? c.decodeIfPresent([ScheduleTemplate].self, forKey: .templates)) ?? []
        rules = (try? c.decodeIfPresent([ScheduleRule].self, forKey: .rules)) ?? []
        overrides = (try? c.decodeIfPresent([DayOverride].self, forKey: .overrides)) ?? []
        medsText = (try? c.decodeIfPresent([String: String].self, forKey: .medsText)) ?? [:]
        mealLogs = (try? c.decodeIfPresent([MealLog].self, forKey: .mealLogs)) ?? []
    }
}

/// A slot just finished; drives the full-screen celebration.
struct SlotCelebration: Identifiable, Equatable {
    let id = UUID()
    let slot: DaySlot
    /// Whose doses finished the slot.
    var taker: MedOwner = .mom
    let progress: Double
    let streak: Int
}

/// Everything one full pull returned.
struct RemoteState {
    var pregnancy: RemotePregnancyRow
    var members: [AccountMember]
    var milestones: [RemoteMilestoneRow]
    var medications: [RemoteMedicationRow]
    var follows: [RemoteFollowRow]
    var doses: [RemoteDoseRow]
    /// Doses before this weren't pulled.
    var doseWindowStart: Date
    var templates: [RemoteTemplateRow] = []
    var templateItems: [RemoteTemplateItemRow] = []
    var rules: [RemoteRuleRow] = []
    /// "Just today" rows (`planned_doses.source = override`) from yesterday on.
    var overrideDoses: [RemotePlannedDoseRow] = []
    /// "Just today" wake, bed and meals (`day_routines`) from yesterday on.
    var dayRoutines: [RemoteDayRoutineRow] = []
    /// "My rules" texts as typed (`med_texts`), one per person.
    var medTexts: [RemoteMedTextRow] = []
    /// Meals checked off (`meal_logs`) from yesterday on.
    var mealLogs: [RemoteMealLogRow] = []
}

/// Lets the user reverse the last dose action from a toast.
struct UndoToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let medicationID: UUID
    let scheduledAt: Date
    var isSkip: Bool = false
}

@Observable
final class AppStore {
    /// One store per process, so intents (Live Activity / widget buttons) act on the same data as the UI.
    static let shared = AppStore()

    private(set) var profile: PregnancyProfile?
    private(set) var milestones: [Milestone] = []
    private(set) var onboardingComplete = false
    var disclaimerAccepted = false
    /// Set directly only by the schedule extension (AppStore+Schedule.swift).
    var medications: [Medication] = []
    private(set) var doseLogs: [DoseLog] = []
    private(set) var aiLookupConsent: Bool?
    private(set) var liveActivitiesEnabled = true
    private(set) var remindersSyncEnabled = false
    private(set) var remindersListID: String?
    private(set) var appearance: AppAppearance = .system
    // Stage 4
    private(set) var account: SyncAccount?
    private(set) var followModes: [UUID: FollowMode] = [:]
    private(set) var pendingOps: [SyncOp] = []
    private var opSeq = 0
    private(set) var partnerAlertsEnabled = true
    // Round 1 (edited from AppStore+Schedule.swift)
    var templates: [ScheduleTemplate] = []
    var rules: [ScheduleRule] = []
    var overrides: [DayOverride] = []
    /// "Your meds & rules" exactly as typed, per person (edited from AppStore+MedsText.swift).
    var medsText: [MedOwner: String] = [:]
    /// Meals checked off on Meds today (edited from AppStore+Meals.swift).
    var mealLogs: [MealLog] = []
    /// No-food clashes waiting for Move / Keep on this phone.
    var mealClashes: [MedOwner: [MealClash]] = [:]
    /// Set after a dose is taken off-schedule; Today asks "Just today" or "Update my template".
    var scheduleChange: ScheduleChange?
    /// She left Meds today with a "Shift my day" not saved: the tab bar asks Just today / Every day.
    var shiftNeedsAnswer = false

    /// Modification date of the state file as last read or written by this process.
    private var knownFileDate: Date?

    /// Set when a slot is completed by the user's action; the Meds tab presents the celebration.
    var celebration: SlotCelebration?
    var undoToast: UndoToast?
    /// A dose moved by itself because last night's dose was late (AppStore+LateDoseMoves.swift). Shown until dismissed.
    var autoMoveNotice: AutoMoveNotice? = AutoMoveNotice.loadSaved() {
        didSet { AutoMoveNotice.save(autoMoveNotice) }
    }
    @ObservationIgnored var isAutoMoving = false
    /// The no-food countdown card (app-wide), set when she logs a dose that starts a no-food window.
    var noFoodAlert: NoFoodAlert?
    /// "Eaten" was pressed on the Live Activity during a no-food window: Meds today asks first.
    var pendingMealGuard: MealGuardRequest?
    /// Meds today / Meds & routines: "{Partner}'s" is picked in the person switch (this phone only).
    var medsShowsPartner: Bool = UserDefaults.standard.bool(forKey: "meds.showsPartner") {
        didSet { UserDefaults.standard.set(medsShowsPartner, forKey: "meds.showsPartner") }
    }
    /// Bumped by "Delete all my data" so screens rebuild from scratch instead of keeping open editors.
    var resetGeneration = 0

    /// Taken times cleared by an undo, by dose key, so an accidental undo is one tap to restore.
    /// Kept on this phone only; a new log of that dose clears its entry.
    private(set) var undoneTakenTimes: [String: Date] = {
        let raw = UserDefaults.standard.dictionary(forKey: "meds.undoneTakenTimes") as? [String: Double] ?? [:]
        let cutoff = Date.now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970
        return raw.filter { $0.value > cutoff }.mapValues { Date(timeIntervalSince1970: $0) }
    }() {
        didSet {
            UserDefaults.standard.set(undoneTakenTimes.mapValues(\.timeIntervalSince1970), forKey: "meds.undoneTakenTimes")
        }
    }

    /// Bumped every minute so date-driven views refresh across midnight.
    var now: Date = .now

    private init() {
        SharedStateFile.migrateLegacyFileIfNeeded()
        load()
        if normalizeGapRules() { save() }
    }

    var isOnboarded: Bool { onboardingComplete && profile != nil }

    var sortedMilestones: [Milestone] {
        milestones.sorted { $0.date < $1.date }
    }

    // MARK: - Profile

    func completeOnboarding(with profile: PregnancyProfile) {
        self.profile = profile
        milestones = SuggestedMilestones.make(for: profile)
        disclaimerAccepted = true
        onboardingComplete = true
        if isShared {
            enqueue(.profile, "profile")
            for milestone in milestones where !milestone.isMarker { enqueue(.milestone, milestone.id.uuidString) }
        }
        save()
    }

    /// Updates names and dates; suggested milestones the user hasn't edited follow the new dates.
    func updateProfile(_ newProfile: PregnancyProfile) {
        let datesChanged = profile?.dueDate != newProfile.dueDate
        profile = newProfile
        if datesChanged {
            for index in milestones.indices where milestones[index].isSuggested && !milestones[index].userEdited {
                if let key = milestones[index].suggestionKey,
                   let template = SuggestedMilestones.templates.first(where: { $0.key == key }) {
                    milestones[index].date = SuggestedMilestones.date(for: template, profile: newProfile)
                    if !milestones[index].isMarker { enqueue(.milestone, milestones[index].id.uuidString) }
                }
            }
        }
        enqueue(.profile, "profile")
        save()
    }

    // MARK: - Milestones

    func upsert(_ milestone: Milestone) {
        var oldRemotePhoto: String?
        if let index = milestones.firstIndex(where: { $0.id == milestone.id }) {
            var updated = milestone
            if updated.isSuggested { updated.userEdited = true }
            if milestones[index].photoFilename != updated.photoFilename {
                oldRemotePhoto = milestones[index].photoPath
                updated.photoPath = nil
            }
            milestones[index] = updated
        } else {
            milestones.append(milestone)
        }
        if !milestone.isMarker { enqueue(.milestone, milestone.id.uuidString, photoPath: oldRemotePhoto) }
        save()
    }

    func delete(_ milestone: Milestone) {
        if let filename = milestone.photoFilename { PhotoStore.delete(filename) }
        let remotePhoto = milestones.first(where: { $0.id == milestone.id })?.photoPath
        milestones.removeAll { $0.id == milestone.id }
        if !milestone.isMarker { enqueue(.milestone, milestone.id.uuidString, photoPath: remotePhoto) }
        save()
    }

    func restoreSuggestions() {
        guard let profile else { return }
        let existingKeys = Set(milestones.compactMap(\.suggestionKey))
        let missing = SuggestedMilestones.make(for: profile).filter { !existingKeys.contains($0.suggestionKey ?? "") }
        milestones.append(contentsOf: missing)
        for milestone in missing where !milestone.isMarker { enqueue(.milestone, milestone.id.uuidString) }
        save()
    }

    // MARK: - Medications

    var sortedMedications: [Medication] {
        medications.sorted { ($0.plannedTimes(on: now).first?.minutesFromMidnight ?? 0, $0.shortName) < ($1.plannedTimes(on: now).first?.minutesFromMidnight ?? 0, $1.shortName) }
    }

    func instances(on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: medications, logs: doseLogs)
    }

    /// Saves a medication. `followMode` is this person's "For me" choice (shared pregnancies only).
    func upsertMedication(_ medication: Medication, followMode: FollowMode? = nil) {
        var medication = medication
        var oldRemotePhoto: String?
        if isShared { medication.takerID = memberID(for: medication.owner) }
        if let index = medications.firstIndex(where: { $0.id == medication.id }) {
            let old = medications[index]
            if let oldFile = old.photoFilename, oldFile != medication.photoFilename {
                if !medications.contains(where: { $0.id != old.id && $0.photoFilename == oldFile }) {
                    MedPhotoStore.delete(oldFile)
                    oldRemotePhoto = old.photoPath
                }
                medication.photoPath = nil
            }
            medications[index] = medication
        } else {
            medications.append(medication)
        }
        if let followMode, isShared { followModes[medication.id] = followMode }
        if isShared {
            let parts = splitByTime(medication.id)
            for id in parts {
                enqueue(.medication, id.uuidString, photoPath: id == medication.id ? oldRemotePhoto : nil)
                if followModes[id] != nil { enqueue(.follow, id.uuidString) }
            }
        }
        saveAndReschedule()
    }

    /// Shared pregnancies store one row per dose time: a med with several times becomes several meds.
    /// The first keeps its id; dose history moves with the matching time of day. Returns all resulting ids.
    @discardableResult
    private func splitByTime(_ id: UUID) -> [UUID] {
        guard let index = medications.firstIndex(where: { $0.id == id }) else { return [] }
        let med = medications[index]
        let times = med.times.sorted()
        guard times.count > 1 else { return [id] }
        medications[index].times = [times[0]]
        var ids = [id]
        let cal = PregnancyMath.calendar
        for time in times.dropFirst() {
            var copy = med
            copy.id = UUID()
            copy.times = [time]
            copy.createdAt = .now
            medications.append(copy)
            followModes[copy.id] = followModes[id]
            for logIndex in doseLogs.indices where doseLogs[logIndex].medicationID == id {
                let comps = cal.dateComponents([.hour, .minute], from: doseLogs[logIndex].scheduledAt)
                if comps.hour == time.hour && comps.minute == time.minute {
                    doseLogs[logIndex].medicationID = copy.id
                    enqueue(.dose, SyncOp.doseKey(medicationID: copy.id, scheduledAt: doseLogs[logIndex].scheduledAt))
                    enqueue(.dose, SyncOp.doseKey(medicationID: id, scheduledAt: doseLogs[logIndex].scheduledAt))
                }
            }
            ids.append(copy.id)
        }
        return ids
    }

    /// Stops a medication from today on, keeping its history.
    func stopMedication(_ medication: Medication) {
        guard let index = medications.firstIndex(where: { $0.id == medication.id }) else { return }
        let yesterday = PregnancyMath.addDays(-1, to: now)
        medications[index].endDate = max(yesterday, PregnancyMath.calendar.startOfDay(for: medications[index].startDate))
        medications[index].paused = true
        enqueue(.medication, medication.id.uuidString)
        saveAndReschedule()
    }

    func resumeMedication(_ medication: Medication) {
        guard let index = medications.firstIndex(where: { $0.id == medication.id }) else { return }
        medications[index].endDate = nil
        medications[index].paused = false
        enqueue(.medication, medication.id.uuidString)
        saveAndReschedule()
    }

    /// Removes a medication and all of its dose history.
    func deleteMedication(_ medication: Medication) {
        var remotePhoto: String?
        if let current = medications.first(where: { $0.id == medication.id }), let photo = current.photoFilename,
           !medications.contains(where: { $0.id != current.id && $0.photoFilename == photo }) {
            MedPhotoStore.delete(photo)
            remotePhoto = current.photoPath
        }
        medications.removeAll { $0.id == medication.id }
        doseLogs.removeAll { $0.medicationID == medication.id }
        followModes[medication.id] = nil
        pendingOps.removeAll { ($0.kind == .dose || $0.kind == .follow) && $0.key.hasPrefix(medication.id.uuidString) }
        enqueue(.medication, medication.id.uuidString, photoPath: remotePhoto)
        removeFromSchedules(medication.id)
        saveAndReschedule()
    }

    // MARK: - People & following (stage 4)

    var isShared: Bool { account?.pregnancyID != nil }
    var isSignedIn: Bool { account != nil }
    var myUserID: UUID? { account?.userID }

    /// The role of the person holding this phone. Without sharing, the app is the mom's.
    var viewerRole: MedOwner { isShared ? (account?.myRole ?? .mom) : .mom }

    func memberID(for role: MedOwner) -> UUID? {
        account?.members.first(where: { $0.role == role })?.userID
    }

    func role(of userID: UUID?) -> MedOwner? {
        guard let userID else { return nil }
        return account?.members.first(where: { $0.userID == userID })?.role
    }

    /// First name for a role: the pregnancy's names first, then the member's account name.
    func name(for role: MedOwner) -> String {
        let fromProfile = (role == .mom ? profile?.momName : profile?.partnerName)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !fromProfile.isEmpty { return fromProfile }
        if let member = account?.members.first(where: { $0.role == role }),
           !member.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return member.displayName
        }
        return role == .mom ? "Mom" : "Partner"
    }

    /// "Leo (partner)" style label for the person behind a user id.
    func label(for userID: UUID?) -> String? {
        guard let role = role(of: userID) else { return nil }
        return "\(name(for: role)) (\(role.rawValue))"
    }

    func takerName(_ medication: Medication) -> String { name(for: medication.owner) }

    /// "taken by Leo (partner)" / "taken by you" when shared; nil otherwise.
    func takerLine(_ medication: Medication) -> String? {
        guard isShared else { return nil }
        if isMine(medication) { return "taken by you" }
        return "taken by \(name(for: medication.owner)) (\(medication.owner.rawValue))"
    }

    /// Dose plus who takes it (shared) or "for Leo" (single phone).
    func detailLine(_ medication: Medication) -> String? {
        guard isShared else { return medication.detailLine(partnerName: profile?.partnerName) }
        let dose = medication.dose.trimmingCharacters(in: .whitespaces)
        let parts = [dose.isEmpty ? nil : dose, takerLine(medication)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "logged by you" / "logged by Leo (partner)" when shared and known.
    func loggedByLine(_ log: DoseLog?) -> String? {
        guard isShared, let by = log?.loggedBy else { return nil }
        if by == myUserID { return "logged by you" }
        return label(for: by).map { "logged by \($0)" }
    }

    /// Whose meds the Meds tab shows by default: your own if you take any, otherwise your partner's.
    var defaultMedsPerson: MedOwner {
        medications.contains(where: { $0.owner == viewerRole }) || medications.isEmpty ? viewerRole : viewerRole.other
    }

    func isMine(_ medication: Medication) -> Bool { medication.owner == viewerRole }

    /// Whether this phone shows Live Activities, reminders and partner alerts for the medication.
    func followMode(for medication: Medication) -> FollowMode {
        guard isShared else { return .live }
        if let mode = followModes[medication.id] { return mode }
        return defaultFollowMode(for: medication.owner)
    }

    /// What "For me" starts as: your own meds and (for the partner) mom's meds are followed live.
    func defaultFollowMode(for owner: MedOwner) -> FollowMode {
        guard isShared else { return .live }
        if owner == viewerRole { return .live }
        if viewerRole == .partner && owner == .mom { return .live }
        return .appOnly
    }

    /// Picker label: "Leo (partner)" when shared, just the name otherwise.
    func pickerLabel(for role: MedOwner) -> String {
        isShared ? "\(name(for: role)) (\(role.rawValue))" : name(for: role)
    }

    func isLiveFollowed(_ medication: Medication) -> Bool { followMode(for: medication) == .live }

    var liveMedications: [Medication] { medications.filter(isLiveFollowed) }

    func liveInstances(on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: liveMedications, logs: doseLogs)
    }

    func setFollowMode(_ mode: FollowMode, for medication: Medication) {
        guard isShared else { return }
        followModes[medication.id] = mode
        enqueue(.follow, medication.id.uuidString)
        saveAndReschedule()
    }

    func setPartnerAlertsEnabled(_ enabled: Bool) {
        partnerAlertsEnabled = enabled
        save()
    }

    // MARK: - Dose logging

    /// Marks a dose taken. `at` is the real moment it was taken; food windows count from it.
    func markTaken(_ instance: DoseInstance, at takenAt: Date = .now, placement: ScheduleChange.Placement = .top) {
        let wasComplete = isSlotComplete(for: instance)
        setLog(for: instance, status: .taken, takenAt: takenAt)
        proposeAfterLogging(instance, placement: placement)
        // The card plays its own warning haptic.
        if !presentNoFoodAlert(after: instance) { Haptics.success() }
        let late = Int((takenAt.timeIntervalSince(instance.scheduledAt) / 60).rounded())
        undoToast = UndoToast(
            message: "\(instance.medication.shortName) taken at \(takenAt.formatted(date: .omitted, time: .shortened))" + (late > 0 ? " (\(Medication.durationText(late)) late)" : ""),
            medicationID: instance.medication.id,
            scheduledAt: instance.scheduledAt
        )
        celebrateIfSlotCompleted(instance, wasComplete: wasComplete)
    }

    func skip(_ instance: DoseInstance) {
        let wasComplete = isSlotComplete(for: instance)
        setLog(for: instance, status: .skipped, takenAt: nil)
        Haptics.tap()
        undoToast = UndoToast(
            message: "\(instance.medication.shortName) skipped",
            medicationID: instance.medication.id,
            scheduledAt: instance.scheduledAt,
            isSkip: true
        )
        celebrateIfSlotCompleted(instance, wasComplete: wasComplete)
    }

    /// Clears the log so the dose is pending again (and its food window returns to the planned time).
    /// A taken time is remembered so logging it again offers "Taken at … (before undo)".
    func undo(medicationID: UUID, scheduledAt: Date) {
        for log in doseLogs where log.medicationID == medicationID && abs(log.scheduledAt.timeIntervalSince(scheduledAt)) < 30 {
            let key = SyncOp.doseKey(medicationID: log.medicationID, scheduledAt: log.scheduledAt)
            enqueue(.dose, key)
            if log.status == .taken, let takenAt = log.takenAt { undoneTakenTimes[key] = takenAt }
        }
        doseLogs.removeAll { $0.medicationID == medicationID && abs($0.scheduledAt.timeIntervalSince(scheduledAt)) < 30 }
        undoToast = nil
        Haptics.select()
        saveAndReschedule()
    }

    func undo(_ instance: DoseInstance) {
        undo(medicationID: instance.medication.id, scheduledAt: instance.scheduledAt)
    }

    /// The taken time an undo cleared for this dose, if it's still pending.
    func takenTimeBeforeUndo(_ instance: DoseInstance) -> Date? {
        guard instance.isPending else { return nil }
        return undoneTakenTimes[SyncOp.doseKey(medicationID: instance.medication.id, scheduledAt: instance.scheduledAt)]
    }

    /// Corrects when a taken dose was taken, without undoing it. Keeps who logged it.
    /// Food windows and later doses recalculate from the new time; the change panel shows only if later doses move.
    func changeTakenTime(_ instance: DoseInstance, to takenAt: Date, placement: ScheduleChange.Placement) {
        guard let index = doseLogs.firstIndex(where: {
            $0.medicationID == instance.medication.id && abs($0.scheduledAt.timeIntervalSince(instance.scheduledAt)) < 30 && $0.status == .taken
        }) else { return }
        let clamped = min(takenAt, .now)
        guard doseLogs[index].takenAt != clamped else { return }
        doseLogs[index].takenAt = clamped
        enqueue(.dose, SyncOp.doseKey(medicationID: instance.medication.id, scheduledAt: instance.scheduledAt))
        undoToast = nil
        now = .now
        saveAndReschedule()
        proposeAfterLogging(instance, placement: placement)
        Haptics.success()
    }

    /// Used by the notification "Taken" action, widget and Live Activity buttons.
    func markTaken(medicationID: UUID, scheduledAt: Date, at takenAt: Date) {
        guard let instance = instances(on: scheduledAt).first(where: {
            $0.medication.id == medicationID && abs($0.scheduledAt.timeIntervalSince(scheduledAt)) < 30
        }), instance.isPending else { return }
        setLog(for: instance, status: .taken, takenAt: takenAt)
        // Open: the card. In the background (Live Activity, widget, notification action): a time-sensitive notice.
        if UIApplication.shared.applicationState == .active {
            presentNoFoodAlert(after: instance)
        } else if startsNoFood(instance), let alert = activeNoFood(instance.medication.owner) {
            MedNotifications.postNoFoodStarted(alert)
        }
    }

    // MARK: - No-food alert

    /// The running no-food time for one person (today plus last night's carry-over), if any.
    func activeNoFood(_ owner: MedOwner, at now: Date = .now) -> NoFoodAlert? {
        let meds = medications.filter { $0.owner == owner }
        let list = MedsEngine.carryOver(into: now, medications: meds, logs: doseLogs)
            + MedsEngine.instances(on: now, medications: meds, logs: doseLogs)
        return MedsEngine.activeNoFood(list, now: now)
    }

    /// The just-logged dose is the viewer's own and its after-window is still running.
    private func startsNoFood(_ instance: DoseInstance) -> Bool {
        let med = instance.medication
        guard !isShared || isMine(med), med.hasNoFoodWindow, med.noFoodAfterMinutes > 0 else { return false }
        let logged = doseLogs.first {
            $0.medicationID == med.id && abs($0.scheduledAt.timeIntervalSince(instance.scheduledAt)) < 30 && $0.status == .taken
        }
        guard let takenAt = logged?.takenAt else { return false }
        return takenAt.addingTimeInterval(Double(med.noFoodAfterMinutes) * 60) > .now
    }

    @discardableResult
    private func presentNoFoodAlert(after instance: DoseInstance) -> Bool {
        guard startsNoFood(instance), let alert = activeNoFood(instance.medication.owner) else { return false }
        noFoodAlert = alert
        return true
    }

    /// A tap on the "No food until" notification: the card again, while the window still runs.
    func showNoFoodAlertIfActive() {
        let owner: MedOwner = isShared ? viewerRole : (MedOwner.allCases.first { activeNoFood($0) != nil } ?? viewerRole)
        noFoodAlert = activeNoFood(owner)
    }

    /// Changes that came from Apple Reminders. Applied without re-syncing Reminders.
    func applyReminderChanges(taken: [(medicationID: UUID, scheduledAt: Date, takenAt: Date)], cleared: [(medicationID: UUID, scheduledAt: Date)]) {
        guard !taken.isEmpty || !cleared.isEmpty else { return }
        for item in cleared {
            for log in doseLogs where log.medicationID == item.medicationID && abs(log.scheduledAt.timeIntervalSince(item.scheduledAt)) < 30 {
                enqueue(.dose, SyncOp.doseKey(medicationID: log.medicationID, scheduledAt: log.scheduledAt))
            }
            doseLogs.removeAll { $0.medicationID == item.medicationID && abs($0.scheduledAt.timeIntervalSince(item.scheduledAt)) < 30 }
        }
        for item in taken {
            guard let instance = instances(on: item.scheduledAt).first(where: {
                $0.medication.id == item.medicationID && abs($0.scheduledAt.timeIntervalSince(item.scheduledAt)) < 30
            }), instance.isPending else { continue }
            doseLogs.append(DoseLog(medicationID: item.medicationID, scheduledAt: instance.scheduledAt, status: .taken, takenAt: item.takenAt, loggedBy: myUserID))
            enqueue(.dose, SyncOp.doseKey(medicationID: item.medicationID, scheduledAt: instance.scheduledAt))
        }
        now = .now
        saveAndReschedule(syncReminders: false)
    }

    private func setLog(for instance: DoseInstance, status: DoseStatus, takenAt: Date?) {
        doseLogs.removeAll { $0.medicationID == instance.medication.id && abs($0.scheduledAt.timeIntervalSince(instance.scheduledAt)) < 30 }
        doseLogs.append(DoseLog(medicationID: instance.medication.id, scheduledAt: instance.scheduledAt, status: status, takenAt: takenAt, loggedBy: myUserID))
        let key = SyncOp.doseKey(medicationID: instance.medication.id, scheduledAt: instance.scheduledAt)
        enqueue(.dose, key)
        if undoneTakenTimes[key] != nil { undoneTakenTimes[key] = nil }
        now = .now
        saveAndReschedule()
    }

    /// Doses of one person only, so celebrations and streaks never mix two people's meds.
    private func takerMedications(_ owner: MedOwner) -> [Medication] {
        medications.filter { $0.owner == owner }
    }

    private func isSlotComplete(for instance: DoseInstance) -> Bool {
        let meds = takerMedications(instance.medication.owner)
        return MedsEngine.isSlotComplete(instance.slot, instances: MedsEngine.instances(on: instance.scheduledAt, medications: meds, logs: doseLogs))
    }

    private func celebrateIfSlotCompleted(_ instance: DoseInstance, wasComplete: Bool) {
        guard PregnancyMath.calendar.isDate(instance.scheduledAt, inSameDayAs: .now), !wasComplete else { return }
        let owner = instance.medication.owner
        let meds = takerMedications(owner)
        let today = MedsEngine.instances(on: .now, medications: meds, logs: doseLogs)
        guard MedsEngine.isSlotComplete(instance.slot, instances: today) else { return }
        let resolved = today.filter { !$0.isPending }.count
        celebration = SlotCelebration(
            slot: instance.slot,
            taker: owner,
            progress: today.isEmpty ? 1 : Double(resolved) / Double(today.count),
            streak: MedsEngine.gentleStreak(medications: meds, logs: doseLogs, today: .now)
        )
    }

    // MARK: - Sync (stage 4)

    /// Records that something changed locally and should be sent. Only while sharing a pregnancy.
    func enqueue(_ kind: SyncOp.Kind, _ key: String, photoPath: String? = nil) {
        guard isShared else { return }
        opSeq += 1
        if let index = pendingOps.firstIndex(where: { $0.kind == kind && $0.key == key }) {
            pendingOps[index].seq = opSeq
            if pendingOps[index].photoPath == nil { pendingOps[index].photoPath = photoPath }
        } else {
            pendingOps.append(SyncOp(kind: kind, key: key, photoPath: photoPath, seq: opSeq))
        }
        SyncEngine.shared.scheduleFlush()
    }

    /// Removes a sent op, unless it changed again while it was being sent.
    func completeOp(_ op: SyncOp) {
        pendingOps.removeAll { $0.kind == op.kind && $0.key == op.key && $0.seq == op.seq }
        save()
    }

    func hasPendingOp(_ kind: SyncOp.Kind, _ key: String) -> Bool {
        pendingOps.contains { $0.kind == kind && $0.key == key }
    }

    /// Signed in: remember the user (keeps local data).
    func setAccountUser(_ userID: UUID) {
        guard account?.userID != userID else { return }
        account = SyncAccount(userID: userID)
        pendingOps = []
        save()
    }

    func setPregnancy(_ row: RemotePregnancyRow, members: [AccountMember]) {
        guard var acc = account else { return }
        acc.pregnancyID = row.id
        acc.inviteCode = row.invite_code
        acc.creatorID = row.created_by
        if !members.isEmpty { acc.members = members }
        if let me = acc.members.first(where: { $0.userID == acc.userID }) {
            acc.myRole = me.role
        } else if row.created_by == acc.userID {
            acc.myRole = MedOwner(rawValue: row.creator_role) ?? .mom
            acc.members = [AccountMember(userID: acc.userID, role: acc.myRole, displayName: "")]
        }
        account = acc
        save()
    }

    /// Fills in `takerID` once the person exists, so queued meds can be sent.
    func resolveTakers() {
        guard isShared else { return }
        var changed = false
        for index in medications.indices where medications[index].takerID == nil {
            if let id = memberID(for: medications[index].owner) {
                medications[index].takerID = id
                changed = true
            }
        }
        if changed { save() }
    }

    func setMedicationPhotoPath(_ path: String, for id: UUID) {
        guard let photo = medications.first(where: { $0.id == id })?.photoFilename else { return }
        for index in medications.indices where medications[index].photoFilename == photo {
            medications[index].photoPath = path
        }
        save()
    }

    func setMilestonePhotoPath(_ path: String, for id: UUID) {
        guard let index = milestones.firstIndex(where: { $0.id == id }) else { return }
        milestones[index].photoPath = path
        save()
    }

    func adoptDoseID(_ id: UUID, medicationID: UUID, scheduledAt: Date) {
        guard let index = doseLogs.firstIndex(where: { $0.medicationID == medicationID && abs($0.scheduledAt.timeIntervalSince(scheduledAt)) < 1 }),
              doseLogs[index].id != id else { return }
        doseLogs[index].id = id
        save()
    }

    /// First upload after starting a shared pregnancy: one row per dose time, then everything is queued.
    func enqueueEverything(includeProfile: Bool = true) {
        guard isShared else { return }
        for med in medications where med.times.count > 1 { splitByTime(med.id) }
        resolveTakers()
        if includeProfile { enqueue(.profile, "profile") }
        for milestone in milestones where !milestone.isMarker {
            if !includeProfile && milestone.isSuggested && !milestone.userEdited { continue }
            enqueue(.milestone, milestone.id.uuidString)
        }
        for med in medications {
            enqueue(.medication, med.id.uuidString)
            if followModes[med.id] != nil { enqueue(.follow, med.id.uuidString) }
        }
        for log in doseLogs where medications.contains(where: { $0.id == log.medicationID }) {
            enqueue(.dose, SyncOp.doseKey(medicationID: log.medicationID, scheduledAt: log.scheduledAt))
        }
        for owner in medsText.keys { enqueue(.medText, owner.rawValue) }
        enqueueSchedulesForUpload()
        saveAndReschedule()
    }

    /// True when there is anything on this phone that joining would replace.
    var hasLocalData: Bool { profile != nil || !medications.isEmpty || !doseLogs.isEmpty }

    /// Joining someone else's pregnancy: the local copy is replaced by the shared one.
    func resetForJoin() {
        for milestone in milestones {
            if let filename = milestone.photoFilename { PhotoStore.delete(filename) }
        }
        MedPhotoStore.deleteAll()
        profile = nil
        milestones = []
        medications = []
        doseLogs = []
        templates = []
        rules = []
        overrides = []
        mealLogs = []
        mealClashes = [:]
        scheduleChange = nil
        followModes = [:]
        pendingOps = []
        onboardingComplete = false
        celebration = nil
        undoToast = nil
        saveAndReschedule()
    }

    /// Signed out: local data stays on the phone, sharing stops.
    func detachAccount() {
        account = nil
        pendingOps = []
        followModes = [:]
        saveAndReschedule()
    }

    /// The shared pregnancy is gone (left, deleted, or removed elsewhere).
    func detachPregnancy(wipe: Bool) {
        guard var acc = account else { return }
        acc.pregnancyID = nil
        acc.inviteCode = nil
        acc.creatorID = nil
        acc.members = []
        account = acc
        pendingOps = []
        followModes = [:]
        if wipe {
            resetForJoin()
        } else {
            saveAndReschedule()
        }
    }

    /// Merges a full pull. Anything with a pending local change keeps the local version (latest change wins).
    func applyRemote(_ remote: RemoteState) {
        guard var acc = account, acc.pregnancyID == remote.pregnancy.id else { return }
        acc.members = remote.members
        acc.inviteCode = remote.pregnancy.invite_code
        acc.creatorID = remote.pregnancy.created_by
        if let me = remote.members.first(where: { $0.userID == acc.userID }) { acc.myRole = me.role }
        let accountChanged = acc != account
        account = acc

        // Profile
        var newProfile = profile
        if !hasPendingOp(.profile, "profile") {
            let p = remote.pregnancy
            let datingDate = SyncFormat.day(from: p.dating_date) ?? profile?.datingDate ?? .now
            let due = SyncFormat.day(from: p.due_date) ?? profile?.dueDate ?? .now
            newProfile = PregnancyProfile(
                momName: p.mom_name,
                partnerName: p.partner_name ?? "",
                babyNickname: p.baby_nickname ?? "",
                datingMethod: DatingMethod(rawValue: p.dating_method) ?? .dueDate,
                datingDate: datingDate,
                embryoAgeDays: profile?.embryoAgeDays ?? 5,
                dueDate: due
            )
        }

        // Milestones
        let localMilestones = Dictionary(milestones.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newMilestones: [Milestone] = []
        var seen = Set<UUID>()
        for row in remote.milestones {
            seen.insert(row.id)
            if hasPendingOp(.milestone, row.id.uuidString) {
                if let local = localMilestones[row.id] { newMilestones.append(local) }
                continue
            }
            newMilestones.append(Self.milestone(from: row, existing: localMilestones[row.id], profile: newProfile))
        }
        for local in milestones where !seen.contains(local.id) {
            if local.isMarker || hasPendingOp(.milestone, local.id.uuidString) { newMilestones.append(local) }
        }
        if let newProfile {
            if !newMilestones.contains(where: \.isMarker) {
                newMilestones += SuggestedMilestones.make(for: newProfile).filter(\.isMarker)
            }
            for index in newMilestones.indices where newMilestones[index].isMarker && !newMilestones[index].userEdited {
                if let key = newMilestones[index].suggestionKey,
                   let template = SuggestedMilestones.templates.first(where: { $0.key == key }) {
                    newMilestones[index].date = SuggestedMilestones.date(for: template, profile: newProfile)
                }
            }
        }

        // Medications
        let localMeds = Dictionary(medications.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newMeds: [Medication] = []
        var seenMeds = Set<UUID>()
        for row in remote.medications {
            seenMeds.insert(row.id)
            if hasPendingOp(.medication, row.id.uuidString) {
                if var local = localMeds[row.id] {
                    // Days are only ever set from her lines (always as days), so a local "every day" is an old
                    // copy that never had days: the server's days win and the upload carries them.
                    if local.schedule == .daily, row.schedule_type == "specific_days", let days = row.days_of_week, !days.isEmpty {
                        local.schedule = .weekdays(Set(days.map { $0 + 1 }))
                    }
                    newMeds.append(local)
                }
                continue
            }
            let role = remote.members.first(where: { $0.userID == row.taken_by })?.role ?? .mom
            newMeds.append(Self.medication(from: row, role: role, existing: localMeds[row.id]))
        }
        for local in medications where !seenMeds.contains(local.id) && hasPendingOp(.medication, local.id.uuidString) {
            newMeds.append(local)
        }
        let medIDs = Set(newMeds.map(\.id))

        // Follows (mine)
        var newFollows: [UUID: FollowMode] = [:]
        for (id, mode) in followModes where medIDs.contains(id) && hasPendingOp(.follow, id.uuidString) { newFollows[id] = mode }
        for row in remote.follows where row.user_id == acc.userID && medIDs.contains(row.medication_id) {
            if newFollows[row.medication_id] == nil, let mode = FollowMode(rawValue: row.mode) { newFollows[row.medication_id] = mode }
        }

        // Doses (only inside the pulled window; older history stays as it is)
        var newLogs: [DoseLog] = doseLogs.filter { $0.scheduledAt < remote.doseWindowStart && medIDs.contains($0.medicationID) }
        var seenDoses = Set<String>()
        let localByKey = Dictionary(doseLogs.map { (SyncOp.doseKey(medicationID: $0.medicationID, scheduledAt: $0.scheduledAt), $0) }, uniquingKeysWith: { a, _ in a })
        for row in remote.doses where medIDs.contains(row.medication_id) {
            let key = SyncOp.doseKey(medicationID: row.medication_id, scheduledAt: row.scheduled_for)
            guard seenDoses.insert(key).inserted else { continue }
            if hasPendingOp(.dose, key) {
                if let local = localByKey[key] { newLogs.append(local) }
                continue
            }
            newLogs.append(DoseLog(
                id: row.id,
                medicationID: row.medication_id,
                scheduledAt: localByKey[key]?.scheduledAt ?? row.scheduled_for,
                status: DoseStatus(rawValue: row.status) ?? .taken,
                takenAt: row.taken_at,
                loggedAt: localByKey[key]?.loggedAt ?? row.taken_at ?? row.scheduled_for,
                loggedBy: row.logged_by
            ))
        }
        for (key, local) in localByKey where local.scheduledAt >= remote.doseWindowStart && !seenDoses.contains(key) {
            if hasPendingOp(.dose, key) && medIDs.contains(local.medicationID) { newLogs.append(local) }
        }

        let schedule = mergeRemoteSchedules(remote, medIDs: medIDs)
        let textsChanged = mergeRemoteMedTexts(remote)
        let newMealLogs = mergeRemoteMealLogs(remote)

        let changed = textsChanged || accountChanged || newProfile != profile || newMilestones != milestones || newMeds != medications
            || newFollows != followModes || newLogs.sorted(by: Self.logOrder) != doseLogs.sorted(by: Self.logOrder) || !onboardingComplete
            || schedule.templates != templates || schedule.rules != rules || schedule.overrides != overrides
            || newMealLogs != mealLogs.sorted(by: Self.mealOrder)
        guard changed else { return }
        profile = newProfile
        milestones = newMilestones
        medications = newMeds
        followModes = newFollows
        doseLogs = newLogs
        templates = schedule.templates
        rules = schedule.rules
        overrides = schedule.overrides
        mealLogs = newMealLogs
        rebuildPlan()
        replanOwnMealsAfterPull()
        if newProfile != nil {
            onboardingComplete = true
            disclaimerAccepted = true
        }
        now = .now
        saveAndReschedule()
    }

    private static func logOrder(_ a: DoseLog, _ b: DoseLog) -> Bool {
        (a.scheduledAt, a.medicationID.uuidString) < (b.scheduledAt, b.medicationID.uuidString)
    }

    private static func milestone(from row: RemoteMilestoneRow, existing: Milestone?, profile: PregnancyProfile?) -> Milestone {
        let cal = PregnancyMath.calendar
        let date = row.occurs_at ?? existing?.date ?? .now
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let isSuggested = row.is_suggested ?? false
        let template = SuggestedMilestones.templates.first { $0.title == row.title }
        let type: MilestoneType = MilestoneType(rawValue: row.type) ?? template?.type ?? .personal
        var m = existing ?? Milestone(title: row.title, type: type, date: date)
        m.id = row.id
        m.title = row.title
        m.type = type
        m.date = date
        m.hasTime = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0
        m.notes = row.notes ?? ""
        m.isSuggested = isSuggested
        m.completed = row.completed
        if isSuggested, let template {
            m.suggestionKey = template.key
            m.windowLabel = template.window
            if existing == nil, let profile {
                m.userEdited = !cal.isDate(SuggestedMilestones.date(for: template, profile: profile), inSameDayAs: date)
            }
        }
        if m.photoPath != row.photo_path {
            m.photoPath = row.photo_path
            m.photoFilename = row.photo_path.map { ($0 as NSString).lastPathComponent }
        }
        return m
    }

    private static func medication(from row: RemoteMedicationRow, role: MedOwner, existing: Medication?) -> Medication {
        var med = existing ?? Medication(name: row.name, dose: row.dose ?? "")
        med.id = row.id
        med.name = row.name
        med.friendlyName = row.friendly_name ?? ""
        med.owner = role
        med.takerID = row.taken_by
        med.dose = row.dose ?? ""
        med.purpose = row.purpose ?? ""
        if row.schedule_type == "specific_days", let days = row.days_of_week, !days.isEmpty {
            med.schedule = .weekdays(Set(days.map { $0 + 1 }))
        } else {
            med.schedule = .daily
        }
        if let time = row.time_of_day {
            med.managed = false
            med.times = [SyncFormat.time(from: time)]
        } else {
            med.managed = true
            med.times = []
        }
        switch row.food_rule {
        case "empty_stomach": med.foodRule = .emptyStomach
        case "with_food": med.foodRule = .withFood
        default: med.foodRule = .any
        }
        med.noFoodBeforeMinutes = row.no_food_before_min ?? 0
        med.noFoodAfterMinutes = row.no_food_after_min ?? 0
        med.rulesConfirmed = row.rules_confirmed ?? true
        med.notes = row.notes ?? ""
        if let start = SyncFormat.day(from: row.start_date) { med.startDate = start }
        med.endDate = SyncFormat.day(from: row.end_date)
        if let created = row.created_at, existing == nil { med.createdAt = created }
        if med.photoPath != row.photo_path {
            med.photoPath = row.photo_path
            med.photoFilename = row.photo_path.map { ($0 as NSString).lastPathComponent }
        }
        return med
    }

    // MARK: - AI lookup consent

    func setAILookupConsent(_ allowed: Bool) {
        aiLookupConsent = allowed
        save()
    }

    // MARK: - Stage 3 settings

    func setLiveActivitiesEnabled(_ enabled: Bool) {
        liveActivitiesEnabled = enabled
        save()
        LiveActivityController.sync(store: self)
    }

    func setRemindersSyncEnabled(_ enabled: Bool) {
        remindersSyncEnabled = enabled
        save()
        if enabled {
            RemindersSync.shared.sync(store: self)
        } else {
            RemindersSync.shared.removeList(id: remindersListID)
            remindersListID = nil
            save()
        }
    }

    func setRemindersListID(_ id: String?) {
        remindersListID = id
        save()
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        save()
    }

    // MARK: - Export

    /// Writes a readable JSON export of everything Carry stores to a temporary file.
    func exportFile() -> URL? {
        let state = PersistedState(
            profile: profile,
            milestones: milestones,
            onboardingComplete: onboardingComplete,
            disclaimerAccepted: disclaimerAccepted,
            medications: medications,
            doseLogs: doseLogs,
            aiLookupConsent: aiLookupConsent,
            liveActivitiesEnabled: liveActivitiesEnabled,
            remindersSyncEnabled: remindersSyncEnabled,
            remindersListID: nil,
            appearance: appearance,
            templates: templates,
            rules: rules,
            overrides: overrides,
            medsText: Dictionary(uniqueKeysWithValues: medsText.map { ($0.key.rawValue, $0.value) }),
            mealLogs: mealLogs
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Carry-export.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Reset

    func deleteAllData() {
        for milestone in milestones {
            if let filename = milestone.photoFilename { PhotoStore.delete(filename) }
        }
        MedPhotoStore.deleteAll()
        profile = nil
        milestones = []
        onboardingComplete = false
        disclaimerAccepted = false
        medications = []
        doseLogs = []
        templates = []
        rules = []
        overrides = []
        medsText = [:]
        mealLogs = []
        mealClashes = [:]
        scheduleChange = nil
        aiLookupConsent = nil
        celebration = nil
        undoToast = nil
        RemindersSync.shared.removeList(id: remindersListID)
        liveActivitiesEnabled = true
        remindersSyncEnabled = false
        remindersListID = nil
        appearance = .system
        account = nil
        followModes = [:]
        pendingOps = []
        opSeq = 0
        partnerAlertsEnabled = true
        SharedStateFile.delete()
        try? FileManager.default.removeItem(at: SharedStateFile.legacyURL)
        knownFileDate = nil
        MedNotifications.removeAll()
        LiveActivityController.endAll()
        WidgetCenter.shared.reloadAllTimelines()
        resetGeneration += 1
    }

    // MARK: - Persistence

    /// Re-reads the shared file if another process (widget, intent) changed it.
    func reloadIfChangedExternally() {
        let date = SharedStateFile.modificationDate()
        if date != knownFileDate {
            load()
            now = .now
            // A dose logged from the widget may push tomorrow's dose (a gap rule across midnight).
            if autoMoveLateDoses() { saveAndReschedule() }
            // An intent outside the app may have queued a dose.
            if !pendingOps.isEmpty { SyncEngine.shared.scheduleFlush() }
        }
        applyPendingMealTaps()
    }

    private func load() {
        knownFileDate = SharedStateFile.modificationDate()
        guard let data = SharedStateFile.read(),
              let state = try? Self.decoder.decode(PersistedState.self, from: data) else { return }
        profile = state.profile
        milestones = state.milestones
        onboardingComplete = state.onboardingComplete
        disclaimerAccepted = state.disclaimerAccepted
        medications = state.medications
        doseLogs = state.doseLogs
        aiLookupConsent = state.aiLookupConsent
        liveActivitiesEnabled = state.liveActivitiesEnabled
        remindersSyncEnabled = state.remindersSyncEnabled
        remindersListID = state.remindersListID
        appearance = state.appearance
        account = state.account
        followModes = Dictionary(uniqueKeysWithValues: state.followModes.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        pendingOps = state.pendingOps
        opSeq = max(state.opSeq, state.pendingOps.map(\.seq).max() ?? 0)
        partnerAlertsEnabled = state.partnerAlertsEnabled
        templates = state.templates
        rules = state.rules
        overrides = state.overrides
        medsText = Dictionary(uniqueKeysWithValues: state.medsText.compactMap { key, value in MedOwner(rawValue: key).map { ($0, value) } })
        mealLogs = state.mealLogs
    }

    /// The one place med changes fan out: file, notifications, widgets, Live Activity, Reminders.
    func saveAndReschedule(syncReminders: Bool = true) {
        // Any dose logged (here, on the other phone, from a widget or a notification) can push the next dose.
        autoMoveLateDoses()
        refreshMealClashes()
        save()
        MedNotifications.reschedule(store: self)
        LiveActivityController.sync(store: self)
        if syncReminders { RemindersSync.shared.sync(store: self) }
    }

    /// Refreshes everything time-based (on launch / foreground) so rolling windows stay filled.
    func refreshReminders() {
        // A new day: keep the plan filled for today and the next 7 days.
        var changed = rebuildPlan()
        // Opening on a new day: last night's real dose times can move this morning's dose.
        if autoMoveLateDoses() { changed = true }
        if changed { save() }
        MedNotifications.reschedule(store: self)
        LiveActivityController.sync(store: self)
        RemindersSync.shared.sync(store: self)
    }

    func save() {
        let state = PersistedState(
            profile: profile,
            milestones: milestones,
            onboardingComplete: onboardingComplete,
            disclaimerAccepted: disclaimerAccepted,
            medications: medications,
            doseLogs: doseLogs,
            aiLookupConsent: aiLookupConsent,
            liveActivitiesEnabled: liveActivitiesEnabled,
            remindersSyncEnabled: remindersSyncEnabled,
            remindersListID: remindersListID,
            appearance: appearance,
            account: account,
            followModes: Dictionary(uniqueKeysWithValues: followModes.map { ($0.key.uuidString, $0.value) }),
            pendingOps: pendingOps,
            opSeq: opSeq,
            partnerAlertsEnabled: partnerAlertsEnabled,
            liveMedicationIDs: isShared ? liveMedications.map(\.id) : nil,
            templates: templates,
            rules: rules,
            overrides: overrides,
            medsText: Dictionary(uniqueKeysWithValues: medsText.map { ($0.key.rawValue, $0.value) }),
            mealLogs: mealLogs
        )
        guard let data = try? Self.encoder.encode(state) else { return }
        SharedStateFile.write(data)
        knownFileDate = SharedStateFile.modificationDate()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Stores milestone photos as JPEG files on device.
enum PhotoStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MilestonePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ image: UIImage) -> String? {
        let resized = image.resizedToFit(maxDimension: 1600)
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        do {
            try data.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
            return filename
        } catch {
            return nil
        }
    }

    static func image(_ filename: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(filename).path)
    }

    static func fileURL(_ filename: String) -> URL { directory.appendingPathComponent(filename) }

    static func exists(_ filename: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(filename).path) }

    /// Stores a photo downloaded from the shared pregnancy under its original name.
    static func write(_ data: Data, as filename: String) {
        try? data.write(to: fileURL(filename), options: [.atomic, .completeFileProtection])
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }
}

extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }
        let scale = maxDimension / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
