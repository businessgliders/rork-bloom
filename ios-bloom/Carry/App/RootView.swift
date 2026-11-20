import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("syncPromptSeen") private var syncPromptSeen = false
    @State private var showSyncPrompt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The launch splash plays once per cold launch (onboarding plays its own intro).
    @State private var showSplash = AppStore.shared.isOnboarded
    @State private var revealed = !AppStore.shared.isOnboarded
    @State private var permission = NotificationPermission.shared
    @State private var notes = DailyNoteCenter.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The note waits for the no-food card, a celebration, the splash and the sync prompt.
    private var notesReady: Bool {
        store.isOnboarded && !showSplash && !showSyncPrompt
    }

    /// "Week 10, day 2 · about a strawberry" — nothing while tracking is paused.
    private var noteSubtitle: String? {
        guard !store.isTrackingPaused, let profile = store.profile else { return nil }
        let age = profile.progress(on: store.now)
        // "day 0" reads oddly on the first day of a week, so it's just "Week 10" then.
        var text = age.days > 0 ? "Week \(age.weeks), day \(age.days)" : "Week \(age.weeks)"
        if let content = WeekLibrary.week(age.contentWeek), content.week >= 3 { text += " \u{00B7} about \(content.size)" }
        return text
    }

    private var greetingName: String? {
        guard store.isSignedIn else { return nil }
        let name = store.name(for: store.viewerRole)
        return name == "Mom" || name == "Partner" ? nil : name
    }

    /// Existing users who set Carry up before syncing existed get a one-time invite to sign in.
    private var shouldOfferSync: Bool {
        store.isOnboarded && !sync.isSignedIn && !store.isShared && !syncPromptSeen
    }

    var body: some View {
        Group {
            if store.isOnboarded {
                MainTabView()
                    .id(store.resetGeneration)
                    .scaleEffect(revealed || reduceMotion ? 1 : 0.92)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: store.isOnboarded)
        .overlay {
            // After a slot celebration closes, so the two never stack.
            if let alert = store.noFoodAlert, store.isOnboarded, store.celebration == nil {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {}
                        .accessibilityHidden(true)
                    NoFoodCountdownCard(alert: alert) { store.noFoodAlert = nil }
                        .id(alert.id)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.noFoodAlert?.id)
        .overlay {
            // One popup at a time: the no-food card first, then today's note.
            if let note = notes.presentation, notesReady, !store.isTrackingPaused, store.noFoodAlert == nil, store.celebration == nil {
                GeometryReader { geo in
                    // Open Duo: centred in the left pane.
                    let twoPane = sizeClass == .regular && geo.size.width >= 800
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { notes.close() }
                            .accessibilityHidden(true)
                        DailyNoteCard(presentation: note, subtitle: noteSubtitle) { notes.close() }
                            .id(note.id)
                            .frame(width: twoPane ? geo.size.width / 2 : geo.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: twoPane ? .leading : .center)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: notes.presentation?.id)
        .overlay(alignment: .top) {
            // A late dose moved the next one by itself: a quiet card at the top, after any popup.
            if let notice = store.autoMoveNotice, notesReady, store.noFoodAlert == nil,
               store.celebration == nil, notes.presentation == nil {
                AutoMoveBanner(notice: notice,
                               onUndo: { store.undoAutoMove(notice.id) },
                               onDismiss: { store.dismissAutoMoveNotice() })
                    .id(notice.id)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86),
                   value: store.autoMoveNotice?.id)
        .onChange(of: notesReady, initial: true) { _, ready in notes.rootReady = ready }
        .overlay {
            if showSplash {
                LaunchSplash(
                    greetingName: greetingName,
                    onReveal: {
                        withAnimation(.spring(duration: 0.5, bounce: 0.12)) { revealed = true }
                    },
                    onFinish: { showSplash = false }
                )
                .ignoresSafeArea()
            }
        }
        .onOpenURL { url in DeepLinkRouter.shared.handle(url) }
        .fullScreenCover(isPresented: $showSyncPrompt, onDismiss: { syncPromptSeen = true }) {
            SyncPromptView()
        }
        .task(id: sync.sessionRestored) {
            // Wait for the saved session so signed-in users never see the prompt.
            guard sync.sessionRestored else { return }
            notes.didBecomeActive()
            // Let the launch splash finish first.
            while showSplash, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(0.8))
            if shouldOfferSync { showSyncPrompt = true }
            await checkNotifications()
        }
        .sheet(isPresented: $permission.showPrePrompt) { NotificationPrePrompt() }
        // The welcome screen already offers sign-in, so new people never see the old invite.
        .onChange(of: store.isOnboarded) { _, onboarded in
            if onboarded {
                syncPromptSeen = true
                // People who came through welcome + sign-in skipped the old permission step.
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    await checkNotifications()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.reloadIfChangedExternally()
                store.now = .now
                store.refreshReminders()
                sync.didBecomeActive()
                notes.didBecomeActive()
                Task { await checkNotifications() }
            case .background:
                sync.didEnterBackground()
            default:
                break
            }
        }
        .alert("Couldn't sync", isPresented: Binding(
            get: { sync.lastError != nil },
            set: { if !$0 { sync.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { sync.lastError = nil }
        } message: {
            Text(sync.lastError ?? "")
        }
        .task {
            // Keep date-driven screens fresh (e.g. across midnight).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.now = .now
                // Only pushes an update when the content actually changed.
                LiveActivityController.sync(store: store)
                if scenePhase == .active { sync.backstop() }
            }
        }
    }

    /// Reads the permission; offers the pre-prompt only once she is in the app and nothing else is showing.
    private func checkNotifications() async {
        let canOffer = store.isOnboarded && !showSplash && !showSyncPrompt
        await permission.refresh(offerPrompt: canOffer)
    }
}
