import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var momName = ""
    @State private var partnerName = ""
    @State private var babyNickname = ""
    @State private var confirmDelete = false
    @State private var exportURL: URL?
    @State private var remindersDenied = false
    @State private var showAccount = false
    @State private var confirmLeave = false
    @State private var confirmSignOut = false
    @State private var confirmDeleteAccount = false
    @State private var accountBusy = false
    @State private var accountError: String?

    var body: some View {
        NavigationStack {
            Form {
                // Not syncing yet: lead with the invite to sync.
                if !store.isShared { togetherSection }

                Section("You two") {
                    LabeledField(title: "Mom", text: $momName)
                    LabeledField(title: "Partner", text: $partnerName)
                    LabeledField(title: "Baby nickname", text: $babyNickname)
                }

                if store.isShared { togetherSection }

                Section("Pregnancy") {
                    NavigationLink {
                        EditDatesView()
                    } label: {
                        LabeledContent("Due date", value: store.profile?.dueDate.formatted(date: .abbreviated, time: .omitted) ?? "")
                    }
                    Button("Restore typical milestones") {
                        store.restoreSuggestions()
                        Haptics.success()
                    }
                }

                Section("Notifications") {
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { store.liveActivitiesEnabled },
                        set: { store.setLiveActivitiesEnabled($0); Haptics.select() }
                    )) {
                        Label("Live Activity", systemImage: "pill.circle.fill")
                    }
                    .tint(Theme.blush)

                    Toggle(isOn: Binding(
                        get: { store.remindersSyncEnabled },
                        set: { newValue in
                            Haptics.select()
                            guard newValue else {
                                store.setRemindersSyncEnabled(false)
                                return
                            }
                            Task {
                                if await Permissions.requestReminders() {
                                    store.setRemindersSyncEnabled(true)
                                } else {
                                    remindersDenied = true
                                }
                            }
                        }
                    )) {
                        Label("Apple Reminders", systemImage: "checklist")
                    }
                    .tint(Theme.sage)
                } header: {
                    Text("Lock Screen & Reminders")
                } footer: {
                    Text("The Live Activity shows the dose that's due and your no-food countdown on the Lock Screen and Dynamic Island. Apple Reminders mirrors yesterday's, today's and tomorrow's doses into a \"Bloom Meds\" list, and ticking one off there logs it here. Turning Reminders off removes that list.")
                }

                Section("Appearance") {
                    Picker(selection: Binding(
                        get: { store.appearance },
                        set: { store.setAppearance($0); Haptics.select() }
                    )) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { store.aiLookupConsent == true },
                        set: { store.setAILookupConsent($0) }
                    )) {
                        Label("AI help with medications", systemImage: "sparkles")
                    }
                    .tint(Theme.blush)
                } header: {
                    Text("AI suggestions")
                } footer: {
                    Text("When on, only the medication text you type, or the label text you review after a scan (personal details removed, never the photo), is sent to Rork's AI service, via Vercel AI Gateway, to Google Gemini to fill in the medication and general timing info. It never suggests a dose. Turn off any time; everything else keeps working.")
                }

                Section {
                    NavigationLink("Privacy policy") { PrivacyPolicyView() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not medical advice")
                            .font(.bloom(.headline, weight: .bold))
                        Text("Bloom shares general information only. Always follow your doctor, midwife or pharmacist. Your health data is never used for analytics or advertising.")
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("About")
                }

                Section("Your data") {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export my data", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Delete all my data", role: .destructive) { confirmDelete = true }
                }
            }
            .font(.bloom(.body))
            .scrollContentBackground(.hidden)
            .background(BloomBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveNames()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                guard let profile = store.profile else { return }
                momName = profile.momName
                partnerName = profile.partnerName
                babyNickname = profile.babyNickname
                exportURL = store.exportFile()
            }
            .alert("Reminders access is off", isPresented: $remindersDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Allow Bloom full access to Reminders in Settings to mirror your doses.")
            }
            .confirmationDialog(
                "Delete all Bloom data?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
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
            .sheet(isPresented: $showAccount) {
                AccountFlowView()
            }
            .confirmationDialog("Leave this pregnancy?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { runAccountAction { try await sync.leavePregnancy() } }
            } message: {
                Text(store.account?.partnerJoined == true
                     ? "\(store.name(for: store.viewerRole.other)) keeps everything. This phone's copy is removed and you'll stay signed in."
                     : "You're the only member, so the shared pregnancy and everything in it is deleted.")
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
                     ? "Your account, your meds and their history are deleted, along with everything on this phone. \(store.name(for: store.viewerRole.other)) keeps the shared pregnancy and milestones. This can't be undone."
                     : "Your account and the shared pregnancy, with all milestones, photos, meds and history, are deleted from Bloom's cloud and this phone. This can't be undone.")
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

    @ViewBuilder
    private var togetherSection: some View {
        if let account = store.account, account.pregnancyID != nil {
            Section {
                ForEach(account.members.sorted { $0.role == .mom && $1.role != .mom }) { member in
                    HStack(spacing: 12) {
                        Text(member.role == .mom ? "🤰" : "🫶").font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memberName(member) + (member.userID == account.userID ? " (you)" : ""))
                                .font(.bloom(.body, weight: .semibold))
                            Text(member.role == .mom ? "Mom" : "Partner")
                                .font(.bloom(.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if member.userID == account.creatorID {
                            Text("Set it up")
                                .font(.bloom(.caption, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if !account.partnerJoined, let code = account.inviteCode {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Invite \(store.name(for: account.myRole.other))")
                            .font(.bloom(.headline, weight: .bold))
                        HStack {
                            Text(code)
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .tracking(6)
                                .foregroundStyle(Theme.blushDeep)
                                .textSelection(.enabled)
                            Spacer()
                            ShareLink(item: "Join our pregnancy on Bloom 🌷 Open Bloom, tap \"Join with a code\" and enter \(code)") {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(BloomSoftButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                Toggle(isOn: Binding(
                    get: { store.partnerAlertsEnabled },
                    set: { value in
                        store.setPartnerAlertsEnabled(value)
                        PushRegistry.shared.setPartnerAlerts(enabled: value)
                        Haptics.select()
                    }
                )) {
                    Label("Partner alerts", systemImage: "bell.badge.fill")
                }
                .tint(Theme.blush)
                if let email = sync.email {
                    LabeledContent("Signed in as", value: email)
                        .font(.bloom(.subheadline))
                }
                syncStatus
            } header: {
                Text("Together")
            } footer: {
                Text("Partner alerts tell you when \(store.name(for: store.viewerRole.other)) logs a dose of a med you follow with a Live Activity. Each med's \"For me\" setting decides what you follow.")
            }

            Section {
                Button("Leave pregnancy", role: .destructive) { confirmLeave = true }
                Button("Sign out") { confirmSignOut = true }
                Button("Delete account", role: .destructive) { confirmDeleteAccount = true }
            } footer: {
                if accountBusy { ProgressView().frame(maxWidth: .infinity) }
            }
            .disabled(accountBusy)
        } else {
            Section {
                Button {
                    showAccount = true
                } label: {
                    HStack(spacing: 14) {
                        Text("💞").font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sync.isSignedIn ? "Start together or join" : "Sync with your partner")
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text("Share milestones and meds, with Live Activities on both phones.")
                                .font(.bloom(.subheadline))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if sync.isSignedIn {
                    Button("Sign out") { confirmSignOut = true }
                    Button("Delete account", role: .destructive) { confirmDeleteAccount = true }
                }
            } header: {
                Text("Together")
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        HStack {
            Image(systemName: sync.isOnline ? "checkmark.icloud.fill" : "icloud.slash.fill")
                .foregroundStyle(sync.isOnline ? Theme.sageDeep : Theme.textSecondary)
            Text(statusText)
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statusText: String {
        if !sync.isOnline {
            return store.pendingOps.isEmpty ? "Offline" : "Offline · \(store.pendingOps.count) change\(store.pendingOps.count == 1 ? "" : "s") waiting"
        }
        if sync.isSyncing || !store.pendingOps.isEmpty { return "Syncing…" }
        return "Up to date"
    }

    private func memberName(_ member: AccountMember) -> String {
        store.name(for: member.role)
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

    private func saveNames() {
        guard var profile = store.profile else { return }
        let mom = momName.trimmingCharacters(in: .whitespaces)
        profile.momName = mom.isEmpty ? profile.momName : mom
        profile.partnerName = partnerName.trimmingCharacters(in: .whitespaces)
        profile.babyNickname = babyNickname.trimmingCharacters(in: .whitespaces)
        if profile != store.profile { store.updateProfile(profile) }
    }
}

private struct LabeledField: View {
    var title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.textSecondary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }
}
