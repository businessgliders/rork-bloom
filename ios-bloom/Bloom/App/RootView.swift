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

    private var greetingName: String? {
        guard store.isSignedIn else { return nil }
        let name = store.name(for: store.viewerRole)
        return name == "Mom" || name == "Partner" ? nil : name
    }

    /// Existing users who set Bloom up before syncing existed get a one-time invite to sign in.
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
            // Let the launch splash finish first.
            while showSplash, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(0.8))
            if shouldOfferSync { showSyncPrompt = true }
        }
        // The welcome screen already offers sign-in, so new people never see the old invite.
        .onChange(of: store.isOnboarded) { _, onboarded in
            if onboarded { syncPromptSeen = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reloadIfChangedExternally()
                store.now = .now
                store.refreshReminders()
                sync.refresh()
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
            }
        }
    }
}
