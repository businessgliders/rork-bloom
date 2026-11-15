import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, names, method, date, reveal, notice, permissions
    }

    @Environment(AppStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showAccount = false

    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var draft = PregnancyProfile(
        momName: "",
        partnerName: "",
        babyNickname: "",
        datingMethod: .ovulation,
        datingDate: PregnancyMath.addDays(-56, to: .now),
        embryoAgeDays: 5,
        dueDate: .now
    )

    var body: some View {
        ZStack {
            BloomBackground()

            // One centred reading column on wide displays (Duo inner, iPad);
            // full width on regular iPhones and the Duo outer display.
            VStack(spacing: 0) {
                if step != .welcome {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                ZStack {
                    stepView
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, hSize == .regular ? 32 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth, value: hSize)
        }
        .onChange(of: draft.datingMethod) { _, _ in draft.recalculateDueDate() }
        .onChange(of: draft.datingDate) { _, _ in draft.recalculateDueDate() }
        .onChange(of: draft.embryoAgeDays) { _, _ in draft.recalculateDueDate() }
        .onAppear { draft.recalculateDueDate() }
        .sheet(isPresented: $showAccount) {
            AccountFlowView()
        }
        // Starting a shared pregnancy as a new user: skip the welcome, prefill the name.
        .onChange(of: sync.startRole) { _, role in
            guard let role else { return }
            prefill(role: role)
            go(to: .names)
        }
    }

    private func prefill(role: MedOwner) {
        let name = sync.accountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if role == .mom, draft.momName.isEmpty { draft.momName = name }
        if role == .partner, draft.partnerName.isEmpty { draft.partnerName = name }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                go(to: Step(rawValue: step.rawValue - 1) ?? .welcome, forward: false)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: .circle)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Back")

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ringTrack)
                    Capsule()
                        .fill(Theme.blush)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: step)
        }
    }

    private var progress: CGFloat {
        CGFloat(step.rawValue) / CGFloat(Step.allCases.count - 1)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .welcome:
            WelcomeStep(
                next: { go(to: .names) },
                accountTitle: sync.isSignedIn ? "Start together or join with a code" : "Sign in or join with a code",
                account: { showAccount = true }
            )
        case .names:
            NamesStep(draft: $draft) { go(to: .method) }
        case .method:
            MethodStep(method: $draft.datingMethod) {
                // Sensible default date for each method.
                switch draft.datingMethod {
                case .dueDate: draft.datingDate = PregnancyMath.addDays(200, to: .now)
                case .lmp: draft.datingDate = PregnancyMath.addDays(-70, to: .now)
                case .ovulation, .ivfTransfer: draft.datingDate = PregnancyMath.addDays(-56, to: .now)
                }
                go(to: .date)
            }
        case .date:
            DateStep(draft: $draft) { go(to: .reveal) }
        case .reveal:
            RevealStep(profile: draft) { go(to: .notice) }
        case .notice:
            NoticeStep { go(to: .permissions) }
        case .permissions:
            PermissionsStep(momName: draft.momName) {
                Haptics.success()
                store.completeOnboarding(with: draft)
                if let role = sync.startRole, sync.isSignedIn {
                    Task {
                        do {
                            try await sync.startPregnancy(role: role)
                        } catch {
                            // Kept on this phone; Settings › Together can try again.
                            sync.startRole = nil
                            sync.lastError = Backend.message(for: error)
                        }
                    }
                }
            }
        }
    }

    private func go(to next: Step, forward: Bool = true) {
        self.forward = forward
        Haptics.tap()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            step = next
        }
    }
}

// MARK: - Shared step layout

struct OnboardingStepLayout<Content: View>: View {
    var emoji: String?
    var title: String
    var subtitle: String?
    var buttonTitle: String
    var buttonEnabled: Bool = true
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let emoji {
                        ZStack {
                            BlobShape(seed: title.count)
                                .fill(Theme.peachSoft)
                                .frame(width: 92, height: 88)
                            Text(emoji).font(.system(size: 46))
                        }
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.bloom(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle)
                                .font(.bloom(.title3))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(buttonTitle, action: action)
                .buttonStyle(BloomPrimaryButtonStyle())
                .disabled(!buttonEnabled)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var next: () -> Void
    var accountTitle: String
    var account: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            CenteredScroll {
                VStack(spacing: 28) {
                    ZStack {
                        BlobShape(seed: 11)
                            .fill(Theme.blushSoft)
                            .frame(width: 280, height: 260)
                        FlowerIllustration(fill: appeared ? 1 : 0)
                            .frame(width: 190, height: 220)
                    }
                    .fittedSquare(280)
                    .frame(maxWidth: 280)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text("Welcome to Bloom")
                            .font(.bloom(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center)
                        Text("A cosy companion for the two of you: watch your little one grow and keep everyday care easy.")
                            .font(.bloom(.title3))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.vertical, 24)
            }
            Button("Let's begin", action: next)
                .buttonStyle(BloomPrimaryButtonStyle())
                .padding(.horizontal, 24)
            Button(accountTitle) {
                Haptics.tap()
                account()
            }
            .font(.bloom(.headline, weight: .bold))
            .foregroundStyle(Theme.blushDeep)
            .padding(.vertical, 14)
            .padding(.bottom, 2)
        }
        .onAppear {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.7).delay(0.2)) { appeared = true }
        }
    }
}

// MARK: - Names

private struct NamesStep: View {
    @Binding var draft: PregnancyProfile
    var next: () -> Void
    @FocusState private var focus: Field?

    enum Field { case mom, partner, baby }

    var body: some View {
        OnboardingStepLayout(
            emoji: "👋",
            title: "Who's on this journey?",
            subtitle: "We'll use your names to cheer you both on.",
            buttonTitle: "Continue",
            buttonEnabled: !draft.momName.trimmingCharacters(in: .whitespaces).isEmpty,
            action: next
        ) {
            VStack(spacing: 14) {
                BloomTextField(label: "Mom's name", placeholder: "e.g. Maya", text: $draft.momName)
                    .focused($focus, equals: .mom)
                    .submitLabel(.next)
                    .onSubmit { focus = .partner }
                BloomTextField(label: "Partner's name", placeholder: "e.g. Leo", text: $draft.partnerName)
                    .focused($focus, equals: .partner)
                    .submitLabel(.next)
                    .onSubmit { focus = .baby }
                BloomTextField(label: "Baby nickname (optional)", placeholder: "e.g. Bean", text: $draft.babyNickname)
                    .focused($focus, equals: .baby)
                    .submitLabel(.done)
            }
        }
        .onAppear { focus = .mom }
    }
}

struct BloomTextField: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: $text)
                .font(.bloom(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(Theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
        }
    }
}

// MARK: - Dating method

private struct MethodStep: View {
    @Binding var method: DatingMethod
    var next: () -> Void

    var body: some View {
        OnboardingStepLayout(
            emoji: "🗓️",
            title: "How should we date your pregnancy?",
            subtitle: "Pick what you know best. You can change it later.",
            buttonTitle: "Next",
            action: next
        ) {
            VStack(spacing: 0) {
                ForEach(DatingMethod.allCases) { option in
                    Button {
                        Haptics.select()
                        withAnimation(.snappy) { method = option }
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: method == option ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 24))
                                .foregroundStyle(method == option ? Theme.blushDeep : Theme.textSecondary.opacity(0.6))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(option.title)
                                        .font(.bloom(.headline, weight: .bold))
                                        .foregroundStyle(Theme.text)
                                    if option == .ovulation {
                                        Text("Default")
                                            .font(.bloom(.caption2, weight: .bold))
                                            .foregroundStyle(Theme.sageDeep)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Theme.sageSoft, in: .capsule)
                                    }
                                }
                                Text(option.subtitle)
                                    .font(.bloom(.subheadline))
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(method == option ? .isSelected : [])

                    if option != DatingMethod.allCases.last {
                        Divider().overlay(Theme.ringTrack)
                    }
                }
            }
            .bloomCard(padding: 18)
        }
    }
}

// MARK: - Date

private struct DateStep: View {
    @Binding var draft: PregnancyProfile
    var next: () -> Void

    var body: some View {
        OnboardingStepLayout(
            emoji: draft.datingMethod == .dueDate ? "🍼" : "📅",
            title: draft.datingMethod.datePrompt,
            subtitle: nil,
            buttonTitle: "Calculate",
            action: next
        ) {
            VStack(spacing: 16) {
                DatePicker(
                    draft.datingMethod.datePrompt,
                    selection: $draft.datingDate,
                    in: PregnancyMath.allowedRange(for: draft.datingMethod),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Theme.blushDeep)
                .bloomCard(padding: 12)

                if draft.datingMethod == .ivfTransfer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Embryo age at transfer")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Picker("Embryo age", selection: $draft.embryoAgeDays) {
                            Text("Day 3").tag(3)
                            Text("Day 5").tag(5)
                        }
                        .pickerStyle(.segmented)
                    }
                    .bloomCard(padding: 16)
                }

                let age = draft.progress()
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                        .frame(width: 44, height: 44)
                        .background(Theme.sageSoft, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Due \(draft.dueDate.formatted(.dateTime.month(.wide).day().year()))")
                            .font(.bloom(.headline, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Today: \(age.headline)")
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .bloomCard(padding: 16)
                .animation(.snappy, value: draft.dueDate)
            }
        }
    }
}

// MARK: - Reveal

private struct RevealStep: View {
    var profile: PregnancyProfile
    var next: () -> Void
    @State private var ringProgress: Double = 0
    @State private var confetti = 0

    var body: some View {
        let age = profile.progress()
        let week = WeekLibrary.week(age.contentWeek)
        ZStack {
            VStack(spacing: 0) {
                CenteredScroll {
                    VStack(spacing: 24) {
                        Text("Hello, \(profile.babyName)!")
                            .font(.bloom(.title2, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(age.headline)
                            .font(.bloom(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center)

                        ZStack {
                            ProgressRing(progress: ringProgress, lineWidth: 16)
                            BlobShape(seed: 4)
                                .fill(Theme.peachSoft)
                                .padding(44)
                            Text(week?.emoji ?? "🌱")
                                .font(.system(size: 84))
                        }
                        .fittedSquare(250)
                        .padding(.horizontal, 24)

                        VStack(spacing: 6) {
                            Text("Due \(profile.dueDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                                .font(.bloom(.title3, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            Text("\(age.trimesterTitle) · \(age.daysToGoText)")
                                .font(.bloom(.body))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
                Button("Wonderful", action: next)
                    .buttonStyle(BloomPrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            ConfettiView(trigger: confetti)
        }
        .onAppear {
            withAnimation(.spring(response: 1.4, dampingFraction: 0.9).delay(0.2)) {
                ringProgress = age.ringProgress
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                confetti += 1
                Haptics.celebrate()
            }
        }
    }
}

// MARK: - Notice

private struct NoticeStep: View {
    var next: () -> Void
    @State private var showPrivacy = false

    var body: some View {
        OnboardingStepLayout(
            emoji: "💌",
            title: "A gentle note",
            subtitle: nil,
            buttonTitle: "I understand",
            action: next
        ) {
            VStack(alignment: .leading, spacing: 16) {
                NoticeRow(symbol: "heart.text.square.fill", tint: Theme.blushDeep, fill: Theme.blushSoft,
                          title: "General information, not medical advice",
                          text: "Bloom shares typical information to help you feel prepared. Every pregnancy is different, so always follow your doctor, midwife or pharmacist.")
                NoticeRow(symbol: "lock.fill", tint: Theme.sageDeep, fill: Theme.sageSoft,
                          title: "Your data stays yours",
                          text: "Your health information is never used for analytics or advertising.")
                NoticeRow(symbol: "cross.case.fill", tint: Theme.coralDeep, fill: Theme.coralSoft,
                          title: "In an emergency",
                          text: "If something feels wrong, contact your provider or emergency services right away.")

                Button {
                    showPrivacy = true
                } label: {
                    Label("Read our privacy policy", systemImage: "doc.text")
                }
                .buttonStyle(BloomSoftButtonStyle())
            }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { PrivacyPolicyView() }
        }
    }
}

private struct NoticeRow: View {
    var symbol: String
    var tint: Color
    var fill: Color
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(fill, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.bloom(.headline, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .bloomCard(padding: 16)
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    var momName: String
    var finish: () -> Void

    @State private var notificationsGranted: Bool?
    @State private var remindersGranted: Bool?

    var body: some View {
        OnboardingStepLayout(
            emoji: "🔔",
            title: "Little nudges, when you want them",
            subtitle: "Totally optional. You can change these any time in Settings.",
            buttonTitle: "Let's bloom",
            action: finish
        ) {
            VStack(spacing: 14) {
                PermissionCard(
                    symbol: "bell.badge.fill",
                    tint: Theme.blushDeep,
                    fill: Theme.blushSoft,
                    title: "Dose reminders",
                    text: "A friendly ping when it's time for a medication, and another when you can eat again.",
                    granted: notificationsGranted
                ) {
                    Task { notificationsGranted = await Permissions.requestNotifications() }
                }
                PermissionCard(
                    symbol: "checklist",
                    tint: Theme.sageDeep,
                    fill: Theme.sageSoft,
                    title: "Apple Reminders",
                    text: "Mirror doses into a \"Bloom Meds\" list so they show up everywhere you use Reminders.",
                    granted: remindersGranted
                ) {
                    Task {
                        let granted = await Permissions.requestReminders()
                        remindersGranted = granted
                        if granted { AppStore.shared.setRemindersSyncEnabled(true) }
                    }
                }
            }
        }
        .task {
            let status = await Permissions.notificationStatus()
            if status != .notDetermined { notificationsGranted = status == .authorized || status == .provisional }
            if Permissions.remindersGranted { remindersGranted = true }
        }
    }
}

private struct PermissionCard: View {
    var symbol: String
    var tint: Color
    var fill: Color
    var title: String
    var text: String
    var granted: Bool?
    var request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(fill, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.bloom(.headline, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(text)
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch granted {
            case .some(true):
                Label("All set", systemImage: "checkmark.circle.fill")
                    .font(.bloom(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.sageDeep)
            case .some(false):
                Text("No worries. You can turn this on later in the Settings app.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            case .none:
                Button("Allow", action: request)
                    .buttonStyle(BloomSoftButtonStyle(tint: tint, fill: fill))
            }
        }
        .bloomCard(padding: 18)
        .animation(.snappy, value: granted)
    }
}
