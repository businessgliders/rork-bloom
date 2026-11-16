import SwiftUI
import AuthenticationServices
import CryptoKit

/// The Carry wordmark beside the mark.
struct CarryWordmark: View {
    var size: CGFloat = 40

    var body: some View {
        Text("Carry")
            .font(.system(size: size, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.dayText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Sign-in screen inside the account flow: mark, wordmark, one line, the two ways in, privacy.
struct SignInView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    CarryMark(size: 56)
                    CarryWordmark(size: 40)
                }
                Text("Share milestones and meds with your partner.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.daySecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 24)
            SignInOptions()
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }
}

/// Sign in with Apple, "Continue with email" (opens a sheet) and the privacy line.
/// Used on the welcome screen and in the account flow.
struct SignInOptions: View {
    /// Shown under the email button on the welcome screen ("Use without an account").
    var secondary: (title: String, action: () -> Void)? = nil

    @Environment(SyncEngine.self) private var sync
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showEmail = false

    var body: some View {
        VStack(spacing: 6) {
            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 54)
            .clipShape(.capsule)
            .disabled(busy)
            .overlay {
                if busy {
                    Capsule().fill(.black.opacity(0.35))
                    CarrySpinner(size: 22, color: .white)
                }
            }

            Button {
                Haptics.tap()
                showEmail = true
            } label: {
                Text("Continue with email")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.rose)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 4)

            if let secondary {
                Button {
                    Haptics.tap()
                    secondary.action()
                } label: {
                    Text(secondary.title)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.daySecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PressableStyle())
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.terraText)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Text("Your data stays private to the two of you. Delete it any time in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dayMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .animation(.smooth, value: error)
        .sheet(isPresented: $showEmail) {
            EmailSignInSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't return a sign-in token. Please try again."
                return
            }
            busy = true
            error = nil
            Task {
                do {
                    try await sync.signInWithApple(idToken: token, nonce: nonce, fullName: credential.fullName)
                    Haptics.success()
                } catch {
                    self.error = Backend.message(for: error)
                    Haptics.warning()
                }
                busy = false
            }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code == .canceled { return }
            error = failure.localizedDescription
        }
    }

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Email sign-in and account creation, in a sheet.
struct EmailSignInSheet: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in", create = "Create account"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case name, email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && (mode == .signIn || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 4)

                    if mode == .create {
                        AuthField(symbol: "person.fill", placeholder: "Your first name", text: $name)
                            .textContentType(.givenName)
                            .textInputAutocapitalization(.words)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .email }
                    }
                    AuthField(symbol: "envelope.fill", placeholder: "Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    AuthField(symbol: "lock.fill", placeholder: mode == .create ? "Password (6+ characters)" : "Password",
                              text: $password, secure: true)
                        .textContentType(mode == .create ? .newPassword : .password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.terraText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    Button {
                        submit()
                    } label: {
                        if busy { CarrySpinner(size: 22, color: .white) } else { Text(mode == .signIn ? "Sign in" : "Create account") }
                    }
                    .buttonStyle(BloomPrimaryButtonStyle(tint: Theme.rose))
                    .disabled(!canSubmit || busy)
                    .padding(.top, 4)
                }
                .padding(20)
                .animation(.smooth, value: mode)
                .animation(.smooth, value: error)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.dayCanvas)
            .navigationTitle("Continue with email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { focus = .email }
    }

    private func submit() {
        focus = nil
        busy = true
        error = nil
        Task {
            do {
                let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if mode == .signIn {
                    try await sync.signIn(email: mail, password: password)
                } else {
                    try await sync.signUp(name: name, email: mail, password: password)
                }
                Haptics.success()
                dismiss()
            } catch {
                self.error = Backend.message(for: error)
                Haptics.warning()
            }
            busy = false
        }
    }
}
