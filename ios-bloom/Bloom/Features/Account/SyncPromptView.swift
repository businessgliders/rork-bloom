import SwiftUI

/// One-time invite shown on launch to people who set Bloom up before syncing existed
/// (onboarded, not signed in). Opens the account flow; "Not now" points to Settings → Together.
struct SyncPromptView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var showAccount = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            BloomBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
Image(systemName: "person.2.fill")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(Theme.blushDeep)
                    .scaleEffect(appeared ? 1 : 0.92)
                    .opacity(appeared ? 1 : 0)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("New: Bloom together")
                            .font(.bloom(.caption, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.blushDeep)
                        Text("Sync with your partner")
                            .font(.bloom(.largeTitle, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Sign in to share this pregnancy between your phones. Everything you've added so far comes with you.")
                            .font(.bloom(.title3))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        perk("calendar", "Milestones and photos", "Both of you see every moment as it's added.")
                        perk("pills.fill", "Meds and doses", "Log a dose on one phone and it shows on the other right away.")
                        perk("⏱️", "Live Activities on both phones", "Each of you chooses which meds to follow.")
                    }

                    VStack(spacing: 12) {
                        Button {
                            Haptics.tap()
                            showAccount = true
                        } label: {
                            Text("Sign in and sync")
                        }
                        .buttonStyle(BloomPrimaryButtonStyle())

                        Button {
                            Haptics.select()
                            dismiss()
                        } label: {
                            Text("Not now")
                                .font(.bloom(.body, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(PressableStyle())

                        Text("You can do this anytime in Journey → Settings → Together.")
                            .font(.bloom(.caption))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .padding(.top, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showAccount) {
            AccountFlowView()
        }
        // Finished once this phone joins or starts a shared pregnancy.
        .onChange(of: store.isShared) { _, shared in
            if shared { dismiss() }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.1)) { appeared = true }
        }
    }

    private func perk(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Theme.blushDeep)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .bloomCard()
    }
}
