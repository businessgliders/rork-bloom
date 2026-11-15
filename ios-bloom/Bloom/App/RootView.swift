import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("syncPromptSeen") private var syncPromptSeen = false
    @State private var showSyncPrompt = false

    /// Existing users who set Bloom up before syncing existed get a one-time invite to sign in.
    private var shouldOfferSync: Bool {
        store.isOnboarded && !sync.isSignedIn && !store.isShared && !syncPromptSeen
    }

    var body: some View {
        Group {
            if store.isOnboarded {
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: store.isOnboarded)
        .fullScreenCover(isPresented: $showSyncPrompt, onDismiss: { syncPromptSeen = true }) {
            SyncPromptView()
        }
        .task(id: sync.sessionRestored) {
            // Wait for the saved session so signed-in users never see the prompt.
            guard sync.sessionRestored else { return }
            try? await Task.sleep(for: .seconds(0.8))
            if shouldOfferSync { showSyncPrompt = true }
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
