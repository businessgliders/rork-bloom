import SwiftUI
import AuthenticationServices
import CryptoKit

/// Sign in, then start or join a shared pregnancy. Presented from onboarding and Settings.
struct AccountFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BloomBackground()
                Group {
                    if !sync.isSignedIn {
                        SignInView()
                            .transition(.opacity)
                    } else if sync.isBootstrapping {
                        loader
                    } else if sync.needsSetup {
                        SetupView(onStartNeedsOnboarding: { dismiss() })
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        loader
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .animation(.smooth, value: sync.isSignedIn)
                .animation(.smooth, value: sync.needsSetup)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.bloom(.body, weight: .semibold))
                }
            }
        }
        // Done once this phone is part of a shared pregnancy.
        .onChange(of: store.isShared) { _, shared in
            if shared { dismiss() }
        }
    }

    private var loader: some View {
        VStack(spacing: 14) {
            CarrySpinner(size: 40)
            Text("Getting things ready…")
                .font(.bloom(.headline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AuthField: View {
    var symbol: String
    var placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
                .frame(width: 22)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .font(.bloom(.body, weight: .semibold))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Start or join

struct SetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync

    /// Called when a new user picked a role and onboarding should collect the pregnancy details.
    var onStartNeedsOnboarding: () -> Void

    enum Path { case choose, start, join }

    @State private var path: Path = .choose
    @State private var role: MedOwner?
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                switch path {
                case .choose: chooser
                case .start: startPanel
                case .join: joinPanel
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.coralDeep)
                }
            }
            .padding(24)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: path)
            .animation(.smooth, value: role)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Replace what's on this phone?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Join and use the shared pregnancy", role: .destructive) { join() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone's own pregnancy details, meds and dose history will be removed. Everything in the shared pregnancy is kept.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if path != .choose {
                Button {
                    Haptics.tap()
                    path = .choose
                    error = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.bloom(.subheadline, weight: .bold))
                        .foregroundStyle(Theme.blushDeep)
                }
                .buttonStyle(PressableStyle())
            }
            Text(title)
                .font(.bloom(.largeTitle, weight: .heavy))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.bloom(.title3))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch path {
        case .choose: sync.accountName.isEmpty ? "You're signed in" : "Hi \(sync.accountName)"
        case .start: "Who's setting this up?"
        case .join: "Join with a code"
        }
    }

    private var subtitle: String {
        switch path {
        case .choose: "Start your shared pregnancy, or join the one your partner already set up."
        case .start: "We'll use this to label who's who and to word things for each of you."
        case .join: "Enter the 6-character code from your partner's Carry."
        }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            ChoiceCard(symbol: "leaf.fill", title: "Start our pregnancy",
                       detail: store.isOnboarded ? "Shares what's already in Carry on this phone." : "Set up the details, then invite your partner.",
                       fill: Theme.blushSoft) {
                path = .start
            }
            ChoiceCard(symbol: "key.fill", title: "Join with a code",
                       detail: "Your partner finds it in Settings › You two.",
                       fill: Theme.peachSoft) {
                path = .join
                codeFocused = true
            }
        }
    }

    private var startPanel: some View {
        VStack(spacing: 14) {
            ForEach(MedOwner.allCases) { option in
                Button {
                    Haptics.tap()
                    role = option
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: option == .mom ? "figure.stand" : "person.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.rose).frame(width: 34)
                        Text(option == .mom ? "I'm the mom" : "I'm the partner")
                            .font(.bloom(.title3, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: role == option ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(role == option ? Theme.blushDeep : Theme.ringTrack)
                    }
                    .bloomCard(fill: role == option ? Theme.blushSoft : Theme.surface)
                }
                .buttonStyle(PressableStyle())
            }

            Button {
                start()
            } label: {
                if busy { CarrySpinner(size: 22, color: .white) } else { Text(store.isOnboarded ? "Start and get the invite code" : "Continue") }
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .disabled(role == nil || busy)
            .padding(.top, 6)
        }
    }

    private var joinPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("ABC123", text: $code)
                .font(.system(size: 38, weight: .heavy))
                .tracking(8)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .padding(.vertical, 18)
                .background(Theme.surface, in: .rect(cornerRadius: 24, style: .continuous))
                .onChange(of: code) { _, value in
                    let cleaned = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                    if cleaned != value { code = cleaned }
                }

            Label("Carry shares information, not medical advice. Always follow your care team.", systemImage: "heart.text.square")
                .font(.bloom(.footnote, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Button {
                if store.hasLocalData { confirmDiscard = true } else { join() }
            } label: {
                if busy { CarrySpinner(size: 22, color: .white) } else { Text("Join") }
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .disabled(code.count != 6 || busy)
        }
    }

    private func start() {
        guard let role else { return }
        error = nil
        if !store.isOnboarded {
            // A new user: onboarding collects the details, then the pregnancy is created.
            sync.startRole = role
            onStartNeedsOnboarding()
            return
        }
        busy = true
        Task {
            do {
                try await sync.startPregnancy(role: role)
                Haptics.success()
            } catch {
                self.error = Backend.message(for: error)
                Haptics.warning()
            }
            busy = false
        }
    }

    private func join() {
        busy = true
        error = nil
        Task {
            do {
                try await sync.join(code: code)
                Haptics.success()
            } catch {
                self.error = Backend.message(for: error)
                Haptics.warning()
            }
            busy = false
        }
    }
}

private struct ChoiceCard: View {
    var symbol: String
    var title: String
    var detail: String
    var fill: Color
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    BlobShape(seed: title.count).fill(fill).frame(width: 60, height: 56)
                    Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.rose)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.bloom(.title3, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.leading)
            .bloomCard()
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Welcome after start / join

struct WelcomeSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var welcome: WelcomeSheet

    var body: some View {
        ZStack {
            BloomBackground()
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                ZStack {
                    BlobShape(seed: 5).fill(Theme.blushSoft).frame(width: 150, height: 140)
                    Image(systemName: symbol).font(.system(size: 54, weight: .semibold)).foregroundStyle(Theme.rose)
                }
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.bloom(.largeTitle, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.bloom(.title3))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                if case .invite(let code) = welcome {
                    InviteCodeCard(code: code)
                }
                Spacer(minLength: 8)
                Button(primaryTitle) { dismiss() }
                    .buttonStyle(BloomPrimaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .presentationDetents([.large])
    }

    private var symbol: String {
        if case .joined = welcome { return "person.2.fill" }
        return "envelope.fill"
    }

    private var title: String {
        switch welcome {
        case .invite: "Invite your partner"
        case .joined: "You're in!"
        }
    }

    private var subtitle: String {
        switch welcome {
        case .invite:
            return "They sign in to Carry, tap Join with a code and enter this. You'll both see the same milestones and meds."
        case .joined(let role):
            let other = store.name(for: role.other)
            return "You joined \(other)'s pregnancy as the \(role.rawValue). Milestones and meds now stay in step on both phones."
        }
    }

    private var primaryTitle: String {
        if case .invite = welcome { return "Done" }
        return "Let's go"
    }
}

/// The 6-character code with a share button.
struct InviteCodeCard: View {
    var code: String

    var body: some View {
        VStack(spacing: 14) {
            Text(code)
                .font(.system(size: 40, weight: .heavy))
                .tracking(8)
                .foregroundStyle(Theme.blushDeep)
                .textSelection(.enabled)
                .accessibilityLabel("Invite code \(code.map(String.init).joined(separator: " "))")
            ShareLink(item: "Join our pregnancy on Carry. Open Carry, tap \"Join with a code\" and enter \(code)") {
                Label("Share code", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(BloomSoftButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        }
        .frame(maxWidth: .infinity)
        .bloomCard()
    }
}
