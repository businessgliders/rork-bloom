import Foundation
import Network
import Supabase

/// What to show right after starting or joining a shared pregnancy.
enum WelcomeSheet: Identifiable, Equatable {
    case invite(code: String)
    case joined(role: MedOwner)

    var id: String {
        switch self {
        case .invite(let code): "invite-\(code)"
        case .joined(let role): "joined-\(role.rawValue)"
        }
    }
}

/// Signs in, keeps the local cache and the shared pregnancy in step, and listens for changes.
/// Local edits are queued (`AppStore.pendingOps`) and sent when online; any remote change triggers a full pull.
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var userID: UUID?
    private(set) var email: String?
    private(set) var accountName: String = ""
    private(set) var isBootstrapping = false
    /// True once the saved session (or its absence) has been read at launch.
    private(set) var sessionRestored = false
    /// Signed in, no shared pregnancy yet: show Start / Join.
    private(set) var needsSetup = false
    /// Chosen in setup before onboarding runs (a new user starting a pregnancy).
    var startRole: MedOwner?
    var welcome: WelcomeSheet?
    var lastError: String?
    private(set) var isOnline = true
    private(set) var isSyncing = false

    private var store: AppStore { .shared }
    private var started = false
    private var channel: RealtimeChannelV2?
    private var channelPregnancy: UUID?
    private var realtimeTasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var isFlushing = false
    private var flushAgain = false
    /// Realtime health (hidden debug info and the reconnect logic).
    private(set) var realtimeStatus = "not subscribed"
    private(set) var lastRealtimeEvent: Date?
    private(set) var lastPullAt: Date?
    private var appActive = true
    private var resubscribeTask: Task<Void, Never>?
    private var resubscribeAttempt = 0
    private static let backoff: [Double] = [1, 2, 5, 10]
    private let monitor = NWPathMonitor()

    private init() {}

    var isSignedIn: Bool { userID != nil }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in SyncEngine.shared.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "bloom.network"))
        Task {
            for await (event, session) in Backend.client.auth.authStateChanges {
                await handle(event: event, session: session)
            }
        }
    }

    private func setOnline(_ online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack, store.isShared {
            scheduleFlush()
            requestPull()
            if let pid = store.account?.pregnancyID, channel == nil { Task { await subscribe(pid) } }
        }
    }

    /// Foreground: catch up on anything missed while suspended.
    func refresh() {
        guard store.isShared else { return }
        scheduleFlush()
        requestPull()
    }

    /// scenePhase .active: re-send push tokens, reconnect realtime when it isn't subscribed, pull.
    func didBecomeActive() {
        appActive = true
        guard isSignedIn else { return }
        PushRegistry.shared.registerAll()
        guard store.isShared, let pid = store.account?.pregnancyID else { return }
        scheduleFlush()
        if !isRealtimeHealthy {
            resubscribeAttempt = 0
            resubscribeTask?.cancel()
            resubscribeTask = Task { await resubscribe(pid) }
        } else {
            requestPull()
        }
    }

    func didEnterBackground() {
        appActive = false
        resubscribeTask?.cancel()
        resubscribeTask = nil
    }

    private var isRealtimeHealthy: Bool {
        guard let channel else { return false }
        return channel.status == .subscribed
    }

    /// The 60 s loop's backstop while active: pull when realtime has been quiet for over a minute,
    /// and reconnect if the channel quietly dropped.
    func backstop() {
        guard appActive, store.isShared, let pid = store.account?.pregnancyID else { return }
        if !isRealtimeHealthy, resubscribeTask == nil {
            resubscribeTask = Task { await resubscribe(pid) }
            return
        }
        let quietSince = max(lastRealtimeEvent ?? .distantPast, lastPullAt ?? .distantPast)
        if Date.now.timeIntervalSince(quietSince) > 60 { requestPull(immediately: true) }
    }

    private func resubscribe(_ pid: UUID) async {
        await unsubscribe()
        await subscribe(pid)
        resubscribeTask = nil
        if isRealtimeHealthy {
            resubscribeAttempt = 0
        }
        requestPull(immediately: true)
    }

    /// Closed or errored while active: try again after 1 s, 2 s, 5 s, 10 s, then every 30 s.
    private func scheduleResubscribe() {
        guard appActive, store.isShared, let pid = store.account?.pregnancyID, resubscribeTask == nil else { return }
        let delay = resubscribeAttempt < Self.backoff.count ? Self.backoff[resubscribeAttempt] : 30
        resubscribeAttempt += 1
        realtimeStatus = "reconnecting in \(Int(delay)) s"
        resubscribeTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await resubscribe(pid)
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn:
            if let user = session?.user {
                if userID != user.id || event == .initialSession {
                    await attach(user)
                }
            } else if event == .initialSession, store.account != nil {
                detachLocally()
            }
            if event == .initialSession { sessionRestored = true }
        case .signedOut:
            detachLocally()
        case .userUpdated:
            if let user = session?.user { updateIdentity(user) }
        default:
            break
        }
    }

    private func updateIdentity(_ user: User) {
        userID = user.id
        email = user.email
        if case .string(let name)? = user.userMetadata["full_name"] { accountName = name }
        else if case .string(let name)? = user.userMetadata["name"] { accountName = name }
        AppGroup.setViewerID(user.id.uuidString)
    }

    private func attach(_ user: User) async {
        updateIdentity(user)
        store.setAccountUser(user.id)
        PushRegistry.shared.start()
        if let pid = store.account?.pregnancyID {
            needsSetup = false
            await subscribe(pid)
            scheduleFlush()
            requestPull(immediately: true)
            PushRegistry.shared.registerAll()
        } else {
            await bootstrap()
        }
    }

    /// Looks for an existing membership; without one the user picks Start or Join.
    private func bootstrap() async {
        guard let userID else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            let rows: [RemoteMemberRow] = try await Backend.client.from("pregnancy_members")
                .select().eq("user_id", value: userID).limit(1).execute().value
            if let membership = rows.first {
                let keepLocal = store.hasLocalData
                try await adopt(pregnancyID: membership.pregnancy_id)
                if keepLocal {
                    // Signing in on a phone that already had its own entries: add them, never overwrite shared names or dates.
                    store.enqueueEverything(includeProfile: false)
                }
                needsSetup = false
            } else {
                needsSetup = true
            }
        } catch {
            // Offline: try again when the network comes back.
            needsSetup = store.account?.pregnancyID == nil
            if !Backend.isNetworkError(error) { lastError = Backend.message(for: error) }
        }
    }

    /// Reads the pregnancy row and members, attaches to it and pulls everything.
    private func adopt(pregnancyID: UUID) async throws {
        let row: RemotePregnancyRow = try await Backend.client.from("pregnancies")
            .select().eq("id", value: pregnancyID).single().execute().value
        let members = try await fetchMembers(pregnancyID)
        store.setPregnancy(row, members: members)
        await subscribe(pregnancyID)
        try await pull()
        PushRegistry.shared.registerAll()
        await saveDisplayNameIfNeeded()
    }

    private func detachLocally() {
        userID = nil
        DailyNoteCenter.shared.signedOut()
        email = nil
        accountName = ""
        needsSetup = false
        startRole = nil
        welcome = nil
        AppGroup.setViewerID(nil)
        Task { await unsubscribe() }
        if store.account != nil { store.detachAccount() }
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async throws {
        try await Backend.client.auth.signIn(email: email, password: password)
    }

    func signUp(name: String, email: String, password: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Backend.client.auth.signUp(email: email, password: password, data: ["full_name": .string(trimmed)])
        accountName = trimmed
    }

    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws {
        try await Backend.client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        // Apple shares the name only on the first sign-in, so keep it right away.
        if let given = fullName?.givenName, !given.isEmpty {
            accountName = given
            _ = try? await Backend.client.auth.update(user: UserAttributes(data: ["full_name": .string(given)]))
            await saveDisplayNameIfNeeded(force: true)
        }
    }

    func signOut() async {
        await PushRegistry.shared.removeMyTokens()
        try? await Backend.client.auth.signOut()
        detachLocally()
    }

    private func saveDisplayNameIfNeeded(force: Bool = false) async {
        guard let userID else { return }
        let name = accountName.isEmpty ? store.name(for: store.viewerRole) : accountName
        guard !name.isEmpty, name != "Mom", name != "Partner" else { return }
        _ = try? await Backend.client.from("profiles")
            .upsert(["id": AnyJSON.string(userID.uuidString), "display_name": .string(name)])
            .execute()
    }

    // MARK: - Start / join / leave

    /// Creates the shared pregnancy from this phone's profile and uploads everything on it.
    func startPregnancy(role: MedOwner) async throws {
        guard let userID, let profile = store.profile else { return }
        var payload = profilePayload(profile)
        payload["creator_role"] = .string(role.rawValue)
        payload["created_by"] = .string(userID.uuidString)
        let row: RemotePregnancyRow = try await Backend.client.from("pregnancies")
            .insert(payload).select().single().execute().value
        store.setPregnancy(row, members: [AccountMember(userID: userID, role: role, displayName: accountName)])
        let members = (try? await fetchMembers(row.id)) ?? []
        if !members.isEmpty { store.setPregnancy(row, members: members) }
        store.enqueueEverything()
        needsSetup = false
        startRole = nil
        await subscribe(row.id)
        await flush()
        try? await pull()
        PushRegistry.shared.registerAll()
        await saveDisplayNameIfNeeded()
        welcome = .invite(code: row.invite_code)
    }

    /// Joins with an invite code. The phone's own copy is replaced by the shared one.
    func join(code: String) async throws {
        let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let pregnancyID: UUID = try await Backend.client.rpc("join_pregnancy", params: ["p_code": cleaned]).execute().value
        store.resetForJoin()
        try await adopt(pregnancyID: pregnancyID)
        needsSetup = false
        startRole = nil
        // The partner's name fills in from their account if the creator left it empty.
        if store.viewerRole == .partner, var profile = store.profile, !profile.hasPartner, !accountName.isEmpty {
            profile.partnerName = accountName
            store.updateProfile(profile)
        }
        welcome = .joined(role: store.viewerRole)
    }

    /// Leaves the shared pregnancy. If the partner stays, they become its owner; alone, it is deleted.
    func leavePregnancy() async throws {
        guard let userID, let account = store.account, let pid = account.pregnancyID else { return }
        let partner = account.members.first(where: { $0.userID != userID })
        if account.creatorID == userID {
            if let partner {
                try await Backend.client.from("pregnancies")
                    .update(["created_by": AnyJSON.string(partner.userID.uuidString)]).eq("id", value: pid).execute()
            } else {
                try await Backend.client.from("pregnancies").delete().eq("id", value: pid).execute()
            }
        }
        if partner != nil || account.creatorID != userID {
            try await Backend.client.from("pregnancy_members").delete()
                .eq("pregnancy_id", value: pid).eq("user_id", value: userID).execute()
        }
        await PushRegistry.shared.removeMyTokens()
        await unsubscribe()
        LiveActivityController.endAll()
        store.detachPregnancy(wipe: true)
        needsSetup = true
    }

    /// Deletes the account on the server (see `supabase/functions/delete-account`), then everything on this phone.
    func deleteAccount() async throws {
        await PushRegistry.shared.removeMyTokens()
        _ = try await Backend.client.functions.invoke("delete-account") { data, _ in data }
        try? await Backend.client.auth.signOut(scope: .local)
        detachLocally()
        store.deleteAllData()
    }

    // MARK: - Realtime

    private func subscribe(_ pregnancyID: UUID) async {
        if channel != nil, channelPregnancy == pregnancyID { return }
        await unsubscribe()
        let ch = Backend.client.channel("bloom-\(pregnancyID.uuidString.lowercased())")
        // Unfiltered: delete events can't be filtered and only carry the primary key. RLS limits rows to this pregnancy.
        for table in ["pregnancies", "pregnancy_members", "milestones", "medications", "dose_logs", "medication_follows",
                      "schedule_templates", "template_items", "schedule_rules", "planned_doses", "day_routines", "med_texts", "meal_logs", "daily_notes"] {
            let stream = ch.postgresChange(AnyAction.self, schema: "public", table: table)
            realtimeTasks.append(Task {
                for await _ in stream {
                    SyncEngine.shared.lastRealtimeEvent = .now
                    SyncEngine.shared.requestPull()
                }
            })
        }
        realtimeStatus = "subscribing"
        do {
            try await ch.subscribeWithError()
            channel = ch
            channelPregnancy = pregnancyID
            realtimeStatus = "subscribed"
            // Watches for the channel closing or erroring; cancelled before our own unsubscribe.
            realtimeTasks.append(Task {
                for await status in ch.statusChange {
                    SyncEngine.shared.channelStatusChanged(ch, status: status)
                }
            })
        } catch {
            realtimeTasks.forEach { $0.cancel() }
            realtimeTasks = []
            await Backend.client.removeChannel(ch)
            realtimeStatus = "error: \(error.localizedDescription)"
            scheduleResubscribe()
        }
    }

    private func channelStatusChanged(_ ch: RealtimeChannelV2, status: RealtimeChannelStatus) {
        guard channel === ch else { return }
        switch status {
        case .subscribed:
            realtimeStatus = "subscribed"
            resubscribeAttempt = 0
        case .subscribing: realtimeStatus = "subscribing"
        case .unsubscribing: realtimeStatus = "unsubscribing"
        case .unsubscribed:
            realtimeStatus = "closed"
            scheduleResubscribe()
        @unknown default:
            realtimeStatus = "unknown"
        }
    }

    private func unsubscribe() async {
        realtimeTasks.forEach { $0.cancel() }
        realtimeTasks = []
        let old = channel
        channel = nil
        channelPregnancy = nil
        if let old { await Backend.client.removeChannel(old) }
        realtimeStatus = "not subscribed"
    }

    // MARK: - Pull

    func requestPull(immediately: Bool = false) {
        guard store.isShared else { return }
        pullTask?.cancel()
        pullTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            do { try await pull() } catch {}
        }
    }

    private func fetchMembers(_ pid: UUID) async throws -> [AccountMember] {
        let rows: [RemoteMemberRow] = try await Backend.client.from("pregnancy_members")
            .select().eq("pregnancy_id", value: pid).execute().value
        let ids = rows.map { $0.user_id.uuidString }
        let profiles: [RemoteProfileRow] = ids.isEmpty ? [] : (try? await Backend.client.from("profiles")
            .select("id, display_name").in("id", values: ids).execute().value) ?? []
        return rows.map { row in
            AccountMember(
                userID: row.user_id,
                role: MedOwner(rawValue: row.role) ?? .mom,
                displayName: profiles.first(where: { $0.id == row.user_id })?.display_name ?? ""
            )
        }
    }

    private func pull() async throws {
        guard let account = store.account, let pid = account.pregnancyID else { return }
        isSyncing = true
        defer { isSyncing = false }
        let client = Backend.client
        let pregnancies: [RemotePregnancyRow] = try await client.from("pregnancies").select().eq("id", value: pid).execute().value
        let members = try await fetchMembers(pid)
        guard let pregnancy = pregnancies.first, members.contains(where: { $0.userID == account.userID }) else {
            // Deleted or removed on another phone.
            await unsubscribe()
            LiveActivityController.endAll()
            store.detachPregnancy(wipe: false)
            needsSetup = true
            return
        }
        let windowStart = PregnancyMath.addDays(-45, to: .now)
        async let milestones: [RemoteMilestoneRow] = client.from("milestones").select().eq("pregnancy_id", value: pid).execute().value
        async let meds: [RemoteMedicationRow] = client.from("medications").select().eq("pregnancy_id", value: pid).execute().value
        async let follows: [RemoteFollowRow] = client.from("medication_follows").select("medication_id, user_id, mode")
            .eq("pregnancy_id", value: pid).eq("user_id", value: account.userID).execute().value
        async let doses: [RemoteDoseRow] = client.from("dose_logs").select("id, medication_id, scheduled_for, status, taken_at, logged_by")
            .eq("pregnancy_id", value: pid).gte("scheduled_for", value: SyncFormat.timestamp(windowStart))
            .order("scheduled_for", ascending: false).limit(2000).execute().value
        async let templates: [RemoteTemplateRow] = client.from("schedule_templates").select()
            .eq("pregnancy_id", value: pid).execute().value
        async let items: [RemoteTemplateItemRow] = client.from("template_items").select()
            .eq("pregnancy_id", value: pid).execute().value
        async let rules: [RemoteRuleRow] = client.from("schedule_rules").select()
            .eq("pregnancy_id", value: pid).execute().value
        async let overrides: [RemotePlannedDoseRow] = client.from("planned_doses")
            .select("id, taker_id, medication_id, local_date, scheduled_for, source, template_id, meal_reason")
            .eq("pregnancy_id", value: pid).in("source", values: ["override", "meal_adjust"])
            .gte("local_date", value: SyncFormat.day(PregnancyMath.addDays(-1, to: .now))).execute().value
        async let dayRoutines: [RemoteDayRoutineRow] = client.from("day_routines")
            .select("id, taker_id, local_date, template_id, wake_time, bed_time, meals")
            .eq("pregnancy_id", value: pid)
            .gte("local_date", value: SyncFormat.day(PregnancyMath.addDays(-1, to: .now))).execute().value
        // Missing table or no rows: texts stay as they are on this phone.
        let medTexts: [RemoteMedTextRow] = (try? await client.from("med_texts")
            .select("taker_id, text, updated_by, updated_at").eq("pregnancy_id", value: pid).execute().value) ?? []
        var remote = try await RemoteState(
            pregnancy: pregnancy, members: members, milestones: milestones, medications: meds,
            follows: follows, doses: doses, doseWindowStart: windowStart,
            templates: templates, templateItems: items, rules: rules, overrideDoses: overrides,
            dayRoutines: dayRoutines
        )
        remote.medTexts = medTexts
        // Meals checked off on Meds today, from yesterday on.
        let mealLogs: [RemoteMealLogRow]? = try? await client.from("meal_logs")
            .select("id, taker_id, local_date, meal, planned_at, eaten_at, logged_by, updated_at")
            .eq("pregnancy_id", value: pid)
            .gte("local_date", value: SyncFormat.day(PregnancyMath.addDays(-1, to: .now))).execute().value
        if let mealLogs { remote.mealLogs = mealLogs } else { remote.mealLogs = Self.localMealRows(store) }
        // A partner who just joined makes queued partner meds sendable.
        let hadPartner = store.account?.partnerJoined ?? false
        store.applyRemote(remote)
        lastPullAt = .now
        // Keep reminders filled after every pull, even when nothing in the plan changed.
        MedNotifications.reschedule(store: store)
        if !hadPartner, store.account?.partnerJoined == true { scheduleFlush() }
        lastError = nil
        // Today's note (per person; RLS returns only her own row).
        DailyNoteCenter.shared.fetch()
        await downloadMissingPhotos()
    }

    private func downloadMissingPhotos() async {
        var downloaded = false
        for med in store.medications {
            guard let path = med.photoPath, let file = med.photoFilename, !MedPhotoStore.exists(file) else { continue }
            if let data = try? await Backend.client.storage.from(Backend.medicationPhotosBucket).download(path: path) {
                MedPhotoStore.write(data, as: file)
                downloaded = true
            }
        }
        for milestone in store.milestones {
            guard let path = milestone.photoPath, let file = milestone.photoFilename, !PhotoStore.exists(file) else { continue }
            if let data = try? await Backend.client.storage.from(Backend.milestonePhotosBucket).download(path: path) {
                PhotoStore.write(data, as: file)
                downloaded = true
            }
        }
        if downloaded { store.now = .now }
    }

    // MARK: - Flush

    func scheduleFlush() {
        guard store.isShared else { return }
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    private struct Deferred: Error {}

    /// Sends queued changes in dependency order. Stops at the first network error; drops changes the server rejects.
    func flush() async {
        guard store.isShared, userID != nil else { return }
        if isFlushing { flushAgain = true; return }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushAgain = false
            store.resolveTakers()
            let ops = store.pendingOps.sorted { ($0.kind.order, $0.seq) < ($1.kind.order, $1.seq) }
            var sent = false
            for op in ops {
                do {
                    try await perform(op)
                    store.completeOp(op)
                    sent = true
                } catch is Deferred {
                    continue
                } catch {
                    if Backend.isNetworkError(error) { return }
                    lastError = Backend.message(for: error)
                    store.completeOp(op)
                }
            }
            if sent { requestPull() }
        } while flushAgain
    }

    private func perform(_ op: SyncOp) async throws {
        guard let account = store.account, let pid = account.pregnancyID else { throw Deferred() }
        let client = Backend.client
        switch op.kind {
        case .profile:
            guard let profile = store.profile else { return }
            try await client.from("pregnancies").update(profilePayload(profile)).eq("id", value: pid).execute()

        case .medication:
            guard let id = UUID(uuidString: op.key) else { return }
            if let med = store.medications.first(where: { $0.id == id }) {
                guard let takerID = med.takerID else { throw Deferred() }
                var photoPath = med.photoPath
                if let file = med.photoFilename {
                    let expected = "\(pid.uuidString.lowercased())/\(file)"
                    if photoPath != expected, MedPhotoStore.exists(file) {
                        try await uploadPhoto(MedPhotoStore.fileURL(file), bucket: Backend.medicationPhotosBucket, path: expected)
                        photoPath = expected
                        store.setMedicationPhotoPath(expected, for: id)
                    }
                } else {
                    photoPath = nil
                }
                try await client.from("medications").upsert(medicationPayload(med, pid: pid, takerID: takerID, photoPath: photoPath)).execute()
                if let old = op.photoPath, old != photoPath {
                    _ = try? await client.storage.from(Backend.medicationPhotosBucket).remove(paths: [old])
                }
            } else {
                try await client.from("medications").delete().eq("id", value: id).execute()
                if let old = op.photoPath {
                    _ = try? await client.storage.from(Backend.medicationPhotosBucket).remove(paths: [old])
                }
            }

        case .template:
            guard let id = UUID(uuidString: op.key) else { return }
            try await pushTemplate(id, pid: pid, account: account)

        case .rule:
            guard let id = UUID(uuidString: op.key) else { return }
            if let rule = store.rules.first(where: { $0.id == id }) {
                guard let takerID = store.memberID(for: rule.owner) else { throw Deferred() }
                if store.hasPendingOp(.medication, rule.subjectID.uuidString) { throw Deferred() }
                if let target = rule.targetMedicationID, store.hasPendingOp(.medication, target.uuidString) { throw Deferred() }
                try await client.from("schedule_rules").upsert(rulePayload(rule, pid: pid, takerID: takerID)).execute()
            } else {
                try await client.from("schedule_rules").delete().eq("id", value: id).execute()
            }

        case .plan:
            guard let owner = MedOwner(rawValue: op.key) else { return }
            try await pushPlan(owner, pid: pid)

        case .follow:
            guard let id = UUID(uuidString: op.key) else { return }
            guard let med = store.medications.first(where: { $0.id == id }) else { return }
            if med.takerID == nil || store.hasPendingOp(.medication, op.key) { throw Deferred() }
            let mode = store.followMode(for: med)
            try await client.from("medication_follows").upsert([
                "medication_id": AnyJSON.string(id.uuidString),
                "user_id": .string(account.userID.uuidString),
                "pregnancy_id": .string(pid.uuidString),
                "mode": .string(mode.rawValue),
            ], onConflict: "medication_id,user_id").execute()

        case .milestone:
            guard let id = UUID(uuidString: op.key) else { return }
            if let milestone = store.milestones.first(where: { $0.id == id }) {
                var photoPath = milestone.photoPath
                if let file = milestone.photoFilename {
                    let expected = "\(pid.uuidString.lowercased())/\(file)"
                    if photoPath != expected, PhotoStore.exists(file) {
                        try await uploadPhoto(PhotoStore.fileURL(file), bucket: Backend.milestonePhotosBucket, path: expected)
                        photoPath = expected
                        store.setMilestonePhotoPath(expected, for: id)
                    }
                } else {
                    photoPath = nil
                }
                try await client.from("milestones").upsert(milestonePayload(milestone, pid: pid, photoPath: photoPath)).execute()
                if let old = op.photoPath, old != photoPath {
                    _ = try? await client.storage.from(Backend.milestonePhotosBucket).remove(paths: [old])
                }
            } else {
                try await client.from("milestones").delete().eq("id", value: id).execute()
                if let old = op.photoPath {
                    _ = try? await client.storage.from(Backend.milestonePhotosBucket).remove(paths: [old])
                }
            }

        case .dose:
            guard let (medID, scheduled) = SyncOp.parseDoseKey(op.key) else { return }
            let log = store.doseLogs.first {
                $0.medicationID == medID && abs($0.scheduledAt.timeIntervalSince(scheduled)) < 1
            }
            if let log {
                guard let med = store.medications.first(where: { $0.id == medID }) else { return }
                if med.takerID == nil || store.hasPendingOp(.medication, medID.uuidString) { throw Deferred() }
                let row: RemoteIDRow = try await client.from("dose_logs").upsert([
                    "pregnancy_id": AnyJSON.string(pid.uuidString),
                    "medication_id": .string(medID.uuidString),
                    "scheduled_for": .string(SyncFormat.timestamp(log.scheduledAt)),
                    "status": .string(log.status.rawValue),
                    "taken_at": log.takenAt.map { .string(SyncFormat.timestamp($0)) } ?? .null,
                    "logged_by": .string((log.loggedBy ?? account.userID).uuidString),
                ], onConflict: "medication_id,scheduled_for").select("id").single().execute().value
                store.adoptDoseID(row.id, medicationID: medID, scheduledAt: log.scheduledAt)
            } else {
                try await client.from("dose_logs").delete()
                    .eq("medication_id", value: medID)
                    .eq("scheduled_for", value: SyncFormat.timestamp(scheduled))
                    .execute()
            }

        case .medText:
            guard let owner = MedOwner(rawValue: op.key), let text = store.medsText[owner] else { return }
            guard let takerID = store.memberID(for: owner) else { throw Deferred() }
            try await client.from("med_texts").upsert([
                "pregnancy_id": AnyJSON.string(pid.uuidString),
                "taker_id": .string(takerID.uuidString),
                "text": .string(text),
                "updated_by": .string(account.userID.uuidString),
                "updated_at": .string(SyncFormat.timestamp(store.medsTextEditedAt(owner) ?? .now)),
            ], onConflict: "pregnancy_id,taker_id").execute()

        case .meal:
            guard case let (owner, day, kind)? = SyncOp.parseMealKey(op.key) else { return }
            guard let takerID = store.memberID(for: owner) else { throw Deferred() }
            if let log = store.mealLog(owner, on: day, kind: kind) {
                try await client.from("meal_logs").upsert([
                    "id": AnyJSON.string(log.id.uuidString),
                    "pregnancy_id": .string(pid.uuidString),
                    "taker_id": .string(takerID.uuidString),
                    "local_date": .string(SyncFormat.day(day)),
                    "meal": .string(kind.rawValue),
                    "planned_at": log.plannedAt.map { .string(SyncFormat.timestamp($0)) } ?? .null,
                    "eaten_at": .string(SyncFormat.timestamp(log.eatenAt)),
                    "logged_by": .string(account.userID.uuidString),
                ], onConflict: "taker_id,local_date,meal").execute()
            } else {
                try await client.from("meal_logs").delete()
                    .eq("taker_id", value: takerID).eq("local_date", value: SyncFormat.day(day))
                    .eq("meal", value: kind.rawValue).execute()
            }
        }
    }

    /// If the meal table can't be read, keep what this phone has instead of clearing it.
    private static func localMealRows(_ store: AppStore) -> [RemoteMealLogRow] {
        store.mealLogs.compactMap { log in
            guard let taker = store.memberID(for: log.owner) else { return nil }
            return RemoteMealLogRow(id: log.id, taker_id: taker, local_date: SyncFormat.day(log.date), meal: log.kind.rawValue,
                                    planned_at: log.plannedAt, eaten_at: log.eatenAt, logged_by: log.loggedBy, updated_at: log.updatedAt)
        }
    }

    /// The template row, its meal and medication items, and removal of items no longer in it.
    private func pushTemplate(_ id: UUID, pid: UUID, account: SyncAccount) async throws {
        let client = Backend.client
        guard let template = store.templates.first(where: { $0.id == id }) else {
            try await client.from("schedule_templates").delete().eq("id", value: id).execute()
            return
        }
        guard let takerID = store.memberID(for: template.owner) else { throw Deferred() }
        // Items reference medications, which must exist on the server first.
        if template.doses.contains(where: { store.hasPendingOp(.medication, $0.medicationID.uuidString) }) { throw Deferred() }
        let meals = template.meals.sorted { $0.time < $1.time }
        let mealJSON: [AnyJSON] = meals.map {
            .object([
                "id": .string($0.id.uuidString),
                "name": .string($0.name),
                "time": .string(SyncFormat.time($0.time)),
                "duration_min": .integer($0.durationMinutes),
            ])
        }
        try await client.from("schedule_templates").upsert([
            "id": AnyJSON.string(template.id.uuidString),
            "pregnancy_id": .string(pid.uuidString),
            "taker_id": .string(takerID.uuidString),
            "name": .string(template.name.isEmpty ? ScheduleTemplate.daysLabel(template.days) : template.name),
            "days_of_week": .array(template.days.sorted().map { .integer($0) }),
            "wake_time": .string(SyncFormat.time(template.wake)),
            "bed_time": .string(SyncFormat.time(template.bed)),
            "meals": .array(mealJSON),
            "active": .bool(true),
            "created_by": .string(account.userID.uuidString),
        ]).execute()

        let knownMeds = Set(store.medications.map(\.id))
        var rows: [[String: AnyJSON]] = []
        var order = 0
        for meal in meals {
            rows.append([
                "id": .string(meal.id.uuidString), "template_id": .string(template.id.uuidString),
                "pregnancy_id": .string(pid.uuidString), "kind": .string("meal"), "medication_id": .null,
                "label": .string(meal.name), "time_of_day": .string(SyncFormat.time(meal.time)),
                "duration_min": .integer(meal.durationMinutes), "sort_order": .integer(order), "pinned": .bool(false),
            ])
            order += 1
        }
        for dose in template.doses.sorted(by: { $0.time < $1.time }) where knownMeds.contains(dose.medicationID) {
            rows.append([
                "id": .string(dose.id.uuidString), "template_id": .string(template.id.uuidString),
                "pregnancy_id": .string(pid.uuidString), "kind": .string("medication"),
                "medication_id": .string(dose.medicationID.uuidString), "label": .null,
                "time_of_day": .string(SyncFormat.time(dose.time)), "duration_min": .integer(0),
                "sort_order": .integer(order), "pinned": .bool(dose.pinned),
            ])
            order += 1
        }
        if !rows.isEmpty {
            try await client.from("template_items").upsert(rows).execute()
        }
        var delete = client.from("template_items").delete().eq("template_id", value: template.id)
        if !rows.isEmpty {
            let ids = rows.compactMap { row -> String? in if case .string(let s)? = row["id"] { return s.lowercased() } else { return nil } }
            delete = delete.not("id", operator: .in, value: "(\(ids.joined(separator: ",")))")
        }
        try await delete.execute()
    }

    /// Keeps today and the next 7 days of `planned_doses` for one person matching the local plan.
    private func pushPlan(_ owner: MedOwner, pid: UUID) async throws {
        let client = Backend.client
        guard let takerID = store.memberID(for: owner) else { throw Deferred() }
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: .now)
        let days = (0...7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let meds = store.medications.filter { $0.owner == owner && $0.managed }
        if meds.contains(where: { store.hasPendingOp(.medication, $0.id.uuidString) }) { throw Deferred() }
        // Templates first so template_id references exist.
        if store.templates(for: owner).contains(where: { store.hasPendingOp(.template, $0.id.uuidString) }) { throw Deferred() }
        var rows: [[String: AnyJSON]] = []
        for day in days {
            let override = store.overrides.first { $0.owner == owner && cal.isDate($0.date, inSameDayAs: day) }
            let template = store.template(for: owner, on: day)
            for med in meds {
                guard let time = med.plan[PlanDay.key(day)] else { continue }
                let at = time.date(on: day)
                let templateID = override?.templateID ?? template?.id
                rows.append([
                    "pregnancy_id": .string(pid.uuidString),
                    "taker_id": .string(takerID.uuidString),
                    "medication_id": .string(med.id.uuidString),
                    "local_date": .string(SyncFormat.day(day)),
                    "scheduled_for": .string(SyncFormat.timestamp(at)),
                    "no_food_before_min": .integer(med.foodRule == .emptyStomach ? med.noFoodBeforeMinutes : 0),
                    "no_food_after_min": .integer(med.foodRule == .emptyStomach ? med.noFoodAfterMinutes : 0),
                    "source": .string(override?.adjusted?[med.id] != nil ? "meal_adjust" : (override == nil ? "template" : "override")),
                    "template_id": templateID.map { .string($0.uuidString) } ?? .null,
                    "meal_reason": override?.adjusted?[med.id].map { .string($0.code) } ?? .null,
                ])
            }
        }
        var keep: [String] = []
        if !rows.isEmpty {
            let saved: [RemoteIDRow] = try await client.from("planned_doses")
                .upsert(rows, onConflict: "medication_id,local_date,scheduled_for").select("id").execute().value
            keep = saved.map { $0.id.uuidString.lowercased() }
        }
        var delete = client.from("planned_doses").delete()
            .eq("pregnancy_id", value: pid).eq("taker_id", value: takerID)
            .gte("local_date", value: SyncFormat.day(today))
            .lte("local_date", value: SyncFormat.day(days.last ?? today))
        if !keep.isEmpty { delete = delete.not("id", operator: .in, value: "(\(keep.joined(separator: ",")))") }
        try await delete.execute()
        try await pushDayRoutines(owner, takerID: takerID, pid: pid, days: days)
    }

    /// "Just today" wake, bed and meal changes for the same days, so the other phone shows them too.
    private func pushDayRoutines(_ owner: MedOwner, takerID: UUID, pid: UUID, days: [Date]) async throws {
        let client = Backend.client
        let cal = PregnancyMath.calendar
        var rows: [[String: AnyJSON]] = []
        for day in days {
            guard let o = store.overrides.first(where: { $0.owner == owner && cal.isDate($0.date, inSameDayAs: day) }),
                  o.meals != nil || o.wake != nil || o.bed != nil else { continue }
            let meals: AnyJSON = o.meals.map { list in
                .array(list.map { meal in
                    .object([
                        "id": .string(meal.id.uuidString.lowercased()),
                        "name": .string(meal.name),
                        "time": .string(String(format: "%02d:%02d", meal.time.hour, meal.time.minute)),
                        "duration_min": .integer(meal.durationMinutes),
                    ])
                })
            } ?? .null
            rows.append([
                "pregnancy_id": .string(pid.uuidString),
                "taker_id": .string(takerID.uuidString),
                "local_date": .string(SyncFormat.day(day)),
                "template_id": o.templateID.map { .string($0.uuidString) } ?? .null,
                "wake_time": o.wake.map { .string(SyncFormat.time($0)) } ?? .null,
                "bed_time": o.bed.map { .string(SyncFormat.time($0)) } ?? .null,
                "meals": meals,
            ])
        }
        var keep: [String] = []
        if !rows.isEmpty {
            let saved: [RemoteIDRow] = try await client.from("day_routines")
                .upsert(rows, onConflict: "pregnancy_id,taker_id,local_date").select("id").execute().value
            keep = saved.map { $0.id.uuidString.lowercased() }
        }
        var delete = client.from("day_routines").delete()
            .eq("pregnancy_id", value: pid).eq("taker_id", value: takerID)
            .gte("local_date", value: SyncFormat.day(days.first ?? .now))
            .lte("local_date", value: SyncFormat.day(days.last ?? .now))
        if !keep.isEmpty { delete = delete.not("id", operator: .in, value: "(\(keep.joined(separator: ",")))") }
        try await delete.execute()
    }

    private func rulePayload(_ rule: ScheduleRule, pid: UUID, takerID: UUID) -> [String: AnyJSON] {
        [
            "id": .string(rule.id.uuidString),
            "pregnancy_id": .string(pid.uuidString),
            "taker_id": .string(takerID.uuidString),
            "subject_medication_id": .string(rule.subjectID.uuidString),
            "relation": .string(rule.relation.rawValue),
            "target_type": .string(rule.target.rawValue),
            "target_medication_id": rule.target == .medication ? (rule.targetMedicationID.map { .string($0.uuidString) } ?? .null) : .null,
            "target_meal": rule.target == .meal ? .string(rule.targetMeal ?? "meal") : SyncFormat.optional(rule.targetMeal),
            "min_minutes": rule.minMinutes.map { .integer($0) } ?? .null,
            "max_minutes": rule.maxMinutes.map { .integer($0) } ?? .null,
            "source_text": SyncFormat.text(rule.sourceText),
            "confirmed": .bool(rule.confirmed),
        ]
    }

    private func uploadPhoto(_ url: URL, bucket: String, path: String) async throws {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            _ = try await Backend.client.storage.from(bucket).upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        } catch let error as StorageError where error.statusCode == "409" || error.error == "Duplicate" || error.message.localizedCaseInsensitiveContains("exists") {
            // Already uploaded (same file name); nothing to do.
        }
    }

    // MARK: - Payloads

    private func profilePayload(_ profile: PregnancyProfile) -> [String: AnyJSON] {
        [
            "mom_name": .string(profile.momName.trimmingCharacters(in: .whitespacesAndNewlines)),
            "partner_name": SyncFormat.text(profile.partnerName),
            "baby_nickname": SyncFormat.text(profile.babyNickname),
            "dating_method": .string(profile.datingMethod.rawValue),
            "dating_date": .string(SyncFormat.day(profile.datingDate)),
            "due_date": .string(SyncFormat.day(profile.dueDate)),
            "tracking_paused": .bool(profile.trackingPaused),
            "tracking_paused_at": profile.trackingPausedAt.map { .string(SyncFormat.timestamp($0)) } ?? .null,
            "tracking_paused_by": profile.trackingPausedBy.map { .string($0) } ?? .null,
        ]
    }

    private func medicationPayload(_ med: Medication, pid: UUID, takerID: UUID, photoPath: String?) -> [String: AnyJSON] {
        let time = med.managed
            ? (med.plan[PlanDay.key(.now)] ?? DaySlot.morning.defaultTime)
            : (med.times.sorted().first ?? DaySlot.morning.defaultTime)
        let scheduleType: String
        let days: [AnyJSON]
        switch med.schedule {
        case .daily:
            scheduleType = "daily"
            days = []
        case .weekdays(let set):
            if set.count == 7 {
                scheduleType = "daily"
                days = []
            } else {
                scheduleType = "specific_days"
                days = set.sorted().map { .integer($0 - 1) }
            }
        }
        let foodRule: String = switch med.foodRule {
        case .any: "none"
        case .emptyStomach: "empty_stomach"
        case .withFood: "with_food"
        }
        let today = PregnancyMath.calendar.startOfDay(for: .now)
        let active = med.endDate.map { PregnancyMath.calendar.startOfDay(for: $0) >= today } ?? true
        return [
            "id": .string(med.id.uuidString),
            "pregnancy_id": .string(pid.uuidString),
            "name": .string(med.name),
            "friendly_name": SyncFormat.text(med.friendlyName),
            "dose": SyncFormat.text(med.dose),
            "purpose": SyncFormat.text(med.purpose),
            "schedule_type": .string(scheduleType),
            "days_of_week": .array(days),
            "slot": .string(time.slot.rawValue),
            "time_of_day": med.managed ? .null : .string(SyncFormat.time(time)),
            "food_rule": .string(foodRule),
            "no_food_before_min": .integer(med.foodRule == .emptyStomach ? med.noFoodBeforeMinutes : 0),
            "no_food_after_min": .integer(med.foodRule == .emptyStomach ? med.noFoodAfterMinutes : 0),
            "rules_confirmed": .bool(med.rulesConfirmed),
            "notes": SyncFormat.text(med.notes),
            "start_date": .string(SyncFormat.day(med.startDate)),
            "end_date": med.endDate.map { .string(SyncFormat.day($0)) } ?? .null,
            "active": .bool(active),
            "taken_by": .string(takerID.uuidString),
            "photo_path": SyncFormat.optional(photoPath),
        ]
    }

    private func milestonePayload(_ m: Milestone, pid: UUID, photoPath: String?) -> [String: AnyJSON] {
        let cal = PregnancyMath.calendar
        let occurs = m.hasTime ? m.date : cal.startOfDay(for: m.date)
        var week = 0
        if let profile = store.profile {
            week = min(45, max(0, PregnancyMath.days(from: profile.gestationStart, to: occurs) / 7))
        }
        return [
            "id": .string(m.id.uuidString),
            "pregnancy_id": .string(pid.uuidString),
            "title": .string(m.title),
            "type": .string(m.type.rawValue),
            "occurs_at": .string(SyncFormat.timestamp(occurs)),
            "week": .integer(week),
            "notes": SyncFormat.text(m.notes),
            "photo_path": SyncFormat.optional(photoPath),
            "is_suggested": .bool(m.isSuggested),
            "completed": .bool(m.completed ?? false),
        ]
    }
}
