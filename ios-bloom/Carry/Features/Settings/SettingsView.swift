import SwiftUI
import Supabase
import PostgREST

/// Settings (board 16): the couple card, then Pregnancy, Meds, Daily note, App, Privacy, Account and
/// the danger zone, with the CarryMark and version at the bottom.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var prefs = NotificationPrefs.shared
    @State private var confirmDelete = false
    @State private var exportURL: URL?
    @State private var remindersDenied = false
    @State private var showAccount = false
    @State private var confirmLeave = false
    @State private var confirmPause = false
    @State private var confirmSignOut = false
    @State private var confirmDeleteAccount = false
    @State private var accountBusy = false
    @State private var accountError: String?
    @State private var startOverOwner: MedOwner?
    @State private var showYouTwo = false
    @State private var showDebug = false
    @State private var permission = NotificationPermission.shared

    var body: some View {
        NavigationStack {
            List {
                coupleCard
                pregnancySection
                medsSection
                dailyNoteSection
                appSection
                privacySection
                accountSection
                dangerSection
                footer
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(22)
            .scrollContentBackground(.hidden)
            .background(Theme.dayCanvas.ignoresSafeArea())
            .tint(Theme.rose)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                        .accessibilityIdentifier("settings-done")
                }
            }
            .onAppear { exportURL = store.exportFile() }
            .task {
                await permission.refresh(offerPrompt: false)
                await prefs.load()
            }
            .sheet(isPresented: $showDebug) { SyncDebugView() }
            .navigationDestination(item: $startOverOwner) { who in
                MedsRoutinesView(owner: who, editing: true, onApplied: { startOverOwner = nil })
            }
            .navigationDestination(isPresented: $showYouTwo) { YouTwoView() }
            .alert("Reminders access is off", isPresented: $remindersDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Allow Carry full access to Reminders in Settings to mirror your doses.")
            }
            .confirmationDialog("Delete all Carry data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    let signedIn = sync.isSignedIn
                    store.deleteAllData()
                    if signedIn { Task { await sync.signOut() } }
                    dismiss()
                }
            } message: {
                Text(sync.isSignedIn
                     ? "This removes your names, dates, milestones, photos, medications and dose history from this device and signs you out. Your shared pregnancy stays in your account; use Delete account to remove it."
                     : "This removes your names, dates, milestones, photos, medications and dose history from this device. It can't be undone.")
            }
            .sheet(isPresented: $showAccount) { AccountFlowView() }
            .confirmationDialog("Leave this pregnancy?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { runAccountAction { try await sync.leavePregnancy() } }
                if !store.isTrackingPaused {
                    // The toggle sits in the Pregnancy section right above the row this opens from.
                    Button("Pause tracking instead") { confirmLeave = false; Haptics.tap() }
                }
            } message: {
                Text(store.account?.partnerJoined == true
                     ? "\(otherName) keeps everything. This phone's copy is removed and you'll stay signed in.\nTo keep your medications, pause pregnancy tracking instead."
                     : "You're the only member, so the shared pregnancy and everything in it is deleted.\nTo keep your medications, pause pregnancy tracking instead.")
            }
            .confirmationDialog("Pause pregnancy tracking?", isPresented: $confirmPause, titleVisibility: .visible) {
                Button("Pause") {
                    Haptics.tap()
                    store.setTrackingPaused(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This hides pregnancy content on both phones. Your medications, reminders and history stay as they are. You can turn it back on anytime in Settings.")
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { runAccountAction { await sync.signOut() } }
            } message: {
                Text("Everything stays on this phone, but it stops syncing with your partner until you sign in again.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    runAccountAction {
                        try await sync.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text(store.account?.partnerJoined == true
                     ? "Your account, your meds and their history are deleted, along with everything on this phone. \(otherName) keeps the shared pregnancy and milestones. This can't be undone."
                     : "Your account and the shared pregnancy, with all milestones, photos, meds and history, are deleted from Carry's cloud and this phone. This can't be undone.")
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { accountError != nil },
                set: { if !$0 { accountError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountError ?? "")
            }
        }
    }

    private var otherName: String { store.name(for: store.viewerRole.other) }
    private var hasPregnancy: Bool { store.account?.pregnancyID != nil }

    // MARK: Couple card

    private var coupleCard: some View {
        Section {
            Button {
                Haptics.tap()
                if hasPregnancy { showYouTwo = true } else { showAccount = true }
            } label: {
                HStack(spacing: 14) {
                    CoupleAvatars(mom: store.profile?.momName ?? "", partner: store.profile?.partnerName ?? "", size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coupleName)
                            .font(.system(size: 21, weight: .semibold, design: .serif).italic())
                            .foregroundStyle(Theme.dayText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let profile = store.profile, !store.isTrackingPaused {
                            let age = profile.progress(on: store.now)
                            Text("Week \(age.weeks) \u{00B7} due \(profile.dueDate.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(.system(size: 14))
                                .monospacedDigit()
                                .foregroundStyle(Theme.daySecondary)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(statusColor == Theme.greenDot ? Theme.greenText : Theme.daySecondary)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.dayMuted)
                }
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(
                LinearGradient(colors: [Theme.roseTint, Theme.dayCard], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .accessibilityIdentifier("settings-couple-card")
        }
    }

    private var coupleName: String {
        guard let profile = store.profile else { return "Carry" }
        return profile.hasPartner ? "\(profile.momName) & \(profile.partnerName)" : profile.momName
    }

    private var statusColor: Color {
        guard hasPregnancy else { return Theme.dayMuted }
        if !sync.isOnline { return Theme.terraDot }
        if sync.isSyncing || !store.pendingOps.isEmpty { return Theme.rose }
        return Theme.greenDot
    }

    private var statusText: String {
        guard hasPregnancy else { return sync.isSignedIn ? "Not shared yet \u{00B7} Start or join" : "Not syncing \u{00B7} Share with your partner" }
        if !sync.isOnline {
            return store.pendingOps.isEmpty ? "Offline" : "Offline \u{00B7} \(store.pendingOps.count) change\(store.pendingOps.count == 1 ? "" : "s") waiting"
        }
        if sync.isSyncing || !store.pendingOps.isEmpty { return "Syncing\u{2026}" }
        return "Synced \u{00B7} up to date"
    }

    // MARK: Pregnancy

    private var pregnancySection: some View {
        Section {
            NavigationLink {
                EditDatesView()
            } label: {
                LabeledContent("Due date", value: store.profile?.dueDate.formatted(date: .abbreviated, time: .omitted) ?? "")
            }
            NavigationLink {
                NameEditView(title: "Baby's nickname", field: .baby)
            } label: {
                LabeledContent("Baby's nickname", value: store.profile?.babyNickname.isEmpty == false ? store.profile!.babyNickname : "None")
            }
            HStack {
                Text("Typical milestones")
                Spacer()
                Button("Restore") {
                    store.restoreSuggestions()
                    Haptics.success()
                }
                .fontWeight(.semibold)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings-restore-milestones")
            }
            captionedToggle("Pregnancy tracking",
                            caption: "Turn off to hide the timeline, weeks and baby updates for both of you. Medications keep working.",
                            isOn: Binding(
                                get: { !store.isTrackingPaused },
                                set: { on in
                                    Haptics.select()
                                    if on { store.setTrackingPaused(false) } else { confirmPause = true }
                                }))
                .accessibilityIdentifier("settings-tracking-toggle")
            VStack(alignment: .leading, spacing: 3) {
                Button("Leave pregnancy", role: .destructive) { confirmLeave = true }
                Text("Stop sharing with \(otherName). Your own data stays.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
            }
            .padding(.vertical, 2)
        } header: {
            header("Pregnancy")
        }
        .listRowBackground(Theme.dayCard)
    }

    // MARK: Meds

    private var medsSection: some View {
        Section {
            medsRow(store.viewerRole, title: "My meds & rules")
            if store.isShared {
                medsRow(store.viewerRole.other, title: "\(otherName)'s meds & rules")
            }
            captionedToggle("Live Activity", caption: "Next dose and no-food time on the Lock Screen",
                            isOn: Binding(get: { store.liveActivitiesEnabled },
                                          set: { store.setLiveActivitiesEnabled($0); Haptics.select() }))
            if hasPregnancy {
                captionedToggle("Partner alerts", caption: "When \(otherName) logs a med you follow",
                                isOn: Binding(get: { store.partnerAlertsEnabled }, set: { value in
                                    Haptics.select()
                                    Task { await prefs.setPartnerAlerts(value) }
                                }))
            }
            captionedToggle("Apple Reminders", caption: "Mirror doses into a Carry Meds list",
                            isOn: Binding(get: { store.remindersSyncEnabled }, set: { newValue in
                                Haptics.select()
                                guard newValue else { store.setRemindersSyncEnabled(false); return }
                                Task {
                                    if await Permissions.requestReminders() {
                                        store.setRemindersSyncEnabled(true)
                                    } else {
                                        remindersDenied = true
                                    }
                                }
                            }))
        } header: {
            header("Meds")
        }
        .listRowBackground(Theme.dayCard)
    }

    private func medsRow(_ who: MedOwner, title: String) -> some View {
        let count = store.meds(of: who).count
        return Button {
            startOverOwner = who
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.dayText)
                Spacer()
                Text(count == 0 ? "None yet" : "\(count) med\(count == 1 ? "" : "s")")
                    .foregroundStyle(Theme.daySecondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.dayMuted)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-edit-meds-\(who.rawValue)")
    }

    // MARK: Daily note

    private var dailyNoteSection: some View {
        Section {
            Toggle("Morning note", isOn: prefBinding(\.dailyNote))
                .accessibilityIdentifier("settings-daily-note")
            if prefs.dailyNote {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("settings-note-time")
                Toggle("Show note when I open the app", isOn: notePopupBinding)
                    .accessibilityIdentifier("settings-note-popup")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Note length")
                        Spacer(minLength: 12)
                        Picker("Note length", selection: noteLengthBinding) {
                            Text("Brief").tag(NotificationPrefs.NoteLength.brief)
                            Text("Full").tag(NotificationPrefs.NoteLength.full)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("Brief is one or two lines.")
                        .font(.caption)
                        .foregroundStyle(Theme.dayMuted)
                }
                .accessibilityIdentifier("settings-note-length")
                Toggle("Include meds recap", isOn: prefBinding(\.includeRecap))
                    .accessibilityIdentifier("settings-include-recap")
                if store.viewerRole == .mom && store.isShared {
                    Toggle("Share my meds recap with \(otherName)", isOn: prefBinding(\.shareRecapWithPartner))
                        .accessibilityIdentifier("settings-share-recap")
                }
            }
        } header: {
            header("Daily note")
        } footer: {
            Text(sync.isSignedIn
                 ? "A short note each morning: how Baby is growing, what to expect this week, and yesterday's meds."
                 : "A short note each morning: how Baby is growing, what to expect this week, and yesterday's meds. Sign in to start getting it.")
        }
        .listRowBackground(Theme.dayCard)
        .disabled(!sync.isSignedIn)
        .animation(.snappy, value: prefs.dailyNote)
    }

    private var notePopupBinding: Binding<Bool> {
        Binding(get: { prefs.notePopup }, set: { value in
            Haptics.select()
            Task { await prefs.setNotePopup(value) }
        })
    }

    private var noteLengthBinding: Binding<NotificationPrefs.NoteLength> {
        Binding(get: { prefs.noteLength }, set: { value in
            Haptics.select()
            Task { await prefs.setNoteLength(value) }
        })
    }

    private func prefBinding(_ key: ReferenceWritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: key] }, set: { value in
            prefs[keyPath: key] = value
            Haptics.select()
            Task { await prefs.save() }
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: prefs.noteMinutes / 60, minute: prefs.noteMinutes % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = (c.hour ?? 8) * 60 + (c.minute ?? 30)
            guard minutes != prefs.noteMinutes else { return }
            prefs.noteMinutes = minutes
            Task { await prefs.save() }
        })
    }

    // MARK: App

    private var appSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                Picker("Appearance", selection: Binding(
                    get: { store.appearance },
                    set: { store.setAppearance($0); Haptics.select() }
                )) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option == .system ? "Auto" : option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings-appearance")
            }
            .padding(.vertical, 4)
            captionedToggle("AI help with medications", caption: "Reads what you type. Never suggests a dose.",
                            isOn: Binding(get: { store.aiLookupConsent == true },
                                          set: { store.setAILookupConsent($0); Haptics.select() }))
            NavigationLink("How AI is used") { AIUseView() }
            Button {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            } label: {
                HStack {
                    Text("Notifications").foregroundStyle(Theme.dayText)
                    Spacer()
                    if permission.isOn {
                        Text("On").foregroundStyle(Theme.daySecondary)
                    } else if permission.checked {
                        Text("Off \u{00B7} Turn on")
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.rose)
                    }
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.dayMuted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-notifications")
        } header: {
            header("App")
        }
        .listRowBackground(Theme.dayCard)
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            NavigationLink("Privacy policy") { PrivacyPolicyView() }
            if let exportURL {
                ShareLink(item: exportURL) {
                    HStack {
                        Text("Export my data").foregroundStyle(Theme.dayText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.dayMuted)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            header("Privacy")
        } footer: {
            Text("Carry shares general information, not medical advice. Always follow your doctor, midwife or pharmacist. Your health data is never used for ads.")
        }
        .listRowBackground(Theme.dayCard)
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if sync.isSignedIn {
                LabeledContent("Signed in as", value: sync.email ?? "Apple ID")
                if !hasPregnancy {
                    Button("Start together or join") { showAccount = true }
                }
                Button("Sign out") { confirmSignOut = true }
                    .foregroundStyle(Theme.rose)
                    .accessibilityIdentifier("settings-sign-out")
            } else {
                Button("Sync with your partner") { showAccount = true }
                    .foregroundStyle(Theme.rose)
            }
        } header: {
            header("Account")
        }
        .listRowBackground(Theme.dayCard)
        .disabled(accountBusy)
    }

    private var dangerSection: some View {
        Section {
            Button("Delete all my data", role: .destructive) { confirmDelete = true }
            if sync.isSignedIn {
                Button("Delete account", role: .destructive) { confirmDeleteAccount = true }
            }
        } header: {
            Text("Danger zone")
                .textCase(.uppercase)
                .foregroundStyle(.red)
        } footer: {
            if accountBusy { CarrySpinner(size: 22).frame(maxWidth: .infinity) }
        }
        .listRowBackground(Theme.dayCard)
        .tint(.red)
        .disabled(accountBusy)
    }

    private var footer: some View {
        Section {
            VStack(spacing: 8) {
                CarryMark(size: 26)
                Text("Carry \(Self.version)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dayMuted)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: 0.8) {
                Haptics.tap()
                showDebug = true
            }
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-version")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: Helpers

    private func header(_ text: String) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.dayMuted)
    }

    private func captionedToggle(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.dayText)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
            }
        }
        .tint(Theme.rose)
    }

    private func runAccountAction(_ action: @escaping () async throws -> Void) {
        accountBusy = true
        Task {
            do {
                try await action()
                Haptics.success()
            } catch {
                accountError = Backend.message(for: error)
                Haptics.warning()
            }
            accountBusy = false
        }
    }
}

// MARK: - Avatars

/// Two overlapping initials: mom in rose, partner in green.
struct CoupleAvatars: View {
    var mom: String
    var partner: String
    var size: CGFloat = 46

    var body: some View {
        HStack(spacing: -size * 0.3) {
            InitialAvatar(name: mom, tint: Theme.rose, fill: Theme.roseTint, size: size)
            if !partner.trimmingCharacters(in: .whitespaces).isEmpty {
                InitialAvatar(name: partner, tint: Theme.greenText, fill: Theme.greenTint, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

struct InitialAvatar: View {
    var name: String
    var tint: Color
    var fill: Color
    var size: CGFloat

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold, design: .serif))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: .circle)
            .overlay(Circle().strokeBorder(Theme.dayCard, lineWidth: max(2, size * 0.06)))
    }
}

// MARK: - You two (board 17)

struct YouTwoView: View {
    @Environment(AppStore.self) private var store
    @State private var togetherSince: Date?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    CoupleAvatars(mom: store.profile?.momName ?? "", partner: store.profile?.partnerName ?? "", size: 76)
                    Text(names)
                        .font(.system(size: 26, weight: .semibold, design: .serif).italic())
                        .foregroundStyle(Theme.dayText)
                        .multilineTextAlignment(.center)
                    Text(subline)
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(Theme.daySecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            member(.mom)
            member(.partner)

            if let account = store.account, !account.partnerJoined, let code = account.inviteCode {
                Section {
                    ShareLink(item: "Join our pregnancy on Carry. Open Carry, tap \"Join with a code\" and enter \(code)") {
                        Label("Share invite code", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Theme.rose)
                    }
                    .accessibilityIdentifier("you-two-share-code")
                }
                .listRowBackground(Theme.dayCard)
            }

            Section {
            } footer: {
                Text("You both see the same timeline, milestones and photos. Each of you keeps your own meds; follow the ones you want to hear about.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.dayCanvas.ignoresSafeArea())
        .tint(Theme.rose)
        .navigationTitle("You two")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTogetherSince() }
    }

    private var names: String {
        guard let profile = store.profile else { return "" }
        return profile.hasPartner ? "\(profile.momName) & \(profile.partnerName)" : profile.momName
    }

    private var subline: String {
        var parts: [String] = []
        if let togetherSince { parts.append("Together since \(togetherSince.formatted(.dateTime.month(.abbreviated).day().year()))") }
        if let code = store.account?.inviteCode { parts.append("invite code \(code)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func member(_ role: MedOwner) -> some View {
        let isMe = store.account?.myRole == role
        let joined = store.account?.members.contains { $0.role == role } == true
        return Section {
            NavigationLink {
                NameEditView(title: role == .mom ? "Mom's name" : "Partner's name", field: role == .mom ? .mom : .partner)
            } label: {
                LabeledContent("Name", value: store.name(for: role))
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(joined ? Theme.greenDot : Theme.dayMuted).frame(width: 7, height: 7)
                    Text(joined ? "Joined" : "Not joined yet")
                        .foregroundStyle(joined ? Theme.greenText : Theme.daySecondary)
                }
            }
        } header: {
            Text(role == .mom ? (isMe ? "Mom (you)" : "Mom") : (isMe ? "Partner (you)" : "Partner"))
                .textCase(.uppercase)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dayMuted)
        }
        .listRowBackground(Theme.dayCard)
    }

    private struct MemberRow: Decodable { var joined_at: String }

    /// The latest join date: when the second of you joined (or when it was set up, alone).
    private func loadTogetherSince() async {
        guard let pid = store.account?.pregnancyID else { return }
        do {
            let rows: [MemberRow] = try await Backend.client.from("pregnancy_members")
                .select("joined_at").eq("pregnancy_id", value: pid).execute().value
            let dates = rows.compactMap { Self.parse($0.joined_at) }
            togetherSince = dates.max()
        } catch {
            togetherSince = nil
        }
    }

    private static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// One name, saved when leaving the page.
struct NameEditView: View {
    enum Field { case mom, partner, baby }
    var title: String
    var field: Field
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(title, text: $text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
            } footer: {
                if field == .baby { Text("Shown as \"Baby\" when empty.") }
            }
            .listRowBackground(Theme.dayCard)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.dayCanvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let profile = store.profile else { return }
            switch field {
            case .mom: text = profile.momName
            case .partner: text = profile.partnerName
            case .baby: text = profile.babyNickname
            }
            focused = true
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard var profile = store.profile else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        switch field {
        case .mom: if !value.isEmpty { profile.momName = value }
        case .partner: profile.partnerName = value
        case .baby: profile.babyNickname = value
        }
        if profile != store.profile { store.updateProfile(profile) }
    }
}

/// The full AI disclosure, moved out of the main list.
struct AIUseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("When AI help is on, only the medication text you type, or the label text you review after a scan (personal details removed, never the photo), is sent to Rork's AI service, via Vercel AI Gateway, to Google Gemini to fill in the medication and general timing info.")
                Text("Lines in Meds & routines are read the same way by DeepSeek, or Anthropic Claude as a backup.")
                Text("It never suggests a dose. A fixed set of rules, not the AI, places every time.")
                Text("Turn it off any time in Settings; everything else keeps working.")
            }
            .font(.system(size: 16))
            .foregroundStyle(Theme.dayText)
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.dayCanvas.ignoresSafeArea())
        .navigationTitle("How AI is used")
        .navigationBarTitleDisplayMode(.inline)
    }
}
