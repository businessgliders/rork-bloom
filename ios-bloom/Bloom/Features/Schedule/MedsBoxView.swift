import PhotosUI
import SwiftUI

/// "List all your medications and any rules about timing, food or each other."
/// The AI only reads the text into medications + rules; the schedule engine places the times.
struct MedsBoxView: View {
    var owner: MedOwner
    var onClose: () -> Void
    /// After saving: open the schedule editor.
    var onOpenSchedule: (() -> Void)?

    @Environment(AppStore.self) private var store

    private enum Phase: Equatable { case input, consent, parsing, review, done }

    @State private var phase: Phase = .input
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var meds: [RegimenMedDraft] = []
    @State private var rules: [ScheduleRule] = []
    @State private var questions: [RegimenQuestion] = []
    @State private var confirmed = false
    @State private var violations: [RuleViolation] = []
    @State private var showScanCamera = false
    @State private var showScanPicker = false
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var isReadingLabel = false
    @FocusState private var focused: Bool

    private let example = "Thyroid as soon as I wake up, no food for 30 min after. Iron 4 hours after thyroid, no food 1 hour before or after. Prenatal with lunch. Keep iron and calcium 2 hours apart."

    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }

    var body: some View {
        NavigationStack {
            ZStack {
                BloomBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch phase {
                        case .input: inputStep
                        case .consent: consentStep
                        case .parsing: parsingStep
                        case .review: reviewStep
                        case .done: doneStep
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: phase)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase != .done { Button("Cancel", action: onClose) }
                }
                if phase == .review {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit text") { go(.input) }
                            .tint(Theme.textSecondary)
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanCamera) {
                CameraCaptureView(purpose: .label) { image in
                    showScanCamera = false
                    readLabel(image)
                } onCancel: {
                    showScanCamera = false
                }
            }
            .photosPicker(isPresented: $showScanPicker, selection: $scanPickerItem, matching: .images)
            .onChange(of: scanPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        readLabel(image)
                    }
                    scanPickerItem = nil
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var title: String {
        switch phase {
        case .input, .consent, .parsing: "Medications"
        case .review: "Look right?"
        case .done: "Your plan"
        }
    }

    // MARK: Input

    @ViewBuilder
    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("List all your medications")
                .font(.bloom(.largeTitle, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("…and any rules about timing, food or each other. Bloom plans the times around \(isViewer ? "your" : "\(store.name(for: owner))'s") day.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("e.g. \(example)")
                        .font(.bloom(.body))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.bloom(.body, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .focused($focused)
                    .accessibilityIdentifier("meds-box-text")
            }
            if text.isEmpty {
                Button("Use the example") {
                    Haptics.select()
                    text = example
                }
                .font(.bloom(.footnote, weight: .semibold))
                .tint(Theme.blushDeep)
            }
        }
        .bloomCard()

        if let errorMessage { errorBanner(errorMessage) }

        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                showScanCamera = true
            } label: {
                Label(isReadingLabel ? "Reading…" : "Scan a box", systemImage: "text.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BloomSoftButtonStyle())
            .disabled(isReadingLabel)
            // A PhotosPicker inside a Menu often fails to present; open it from a plain button instead.
            Button {
                Haptics.tap()
                showScanPicker = true
            } label: {
                Label("Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
            .disabled(isReadingLabel)
        }
        Text("Scans are read on this iPhone and added to the text. Names and dates are left out.")
            .font(.bloom(.caption))
            .foregroundStyle(Theme.textSecondary)

        Button {
            submit()
        } label: {
            Label("Read my list", systemImage: "sparkles")
        }
        .buttonStyle(BloomPrimaryButtonStyle())
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
        .accessibilityIdentifier("meds-box-go")
    }

    // MARK: Consent

    @ViewBuilder
    private var consentStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Before Bloom reads it", systemImage: "hand.raised.fill")
                .font(.bloom(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("To read your list, Bloom sends only this text to Rork's AI service, which passes it through Vercel AI Gateway to Google Gemini. It only sorts it into medications and rules; the times are worked out on this iPhone.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("No photos, names or dates. Nothing is saved until you confirm it. You can turn this off any time in Settings.")
                .font(.bloom(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Allow & read") {
                    store.setAILookupConsent(true)
                    run()
                }
                .buttonStyle(BloomPrimaryButtonStyle(tint: Theme.blush))
                .accessibilityIdentifier("ai-consent-allow")
                Button("Not now") { go(.input) }
                    .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
            }
        }
        .bloomCard(fill: Theme.blushSoft)
    }

    private var parsingStep: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.peachDeep)
            Text("Reading your list…")
                .font(.bloom(.title2, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Sorting it into medications and rules.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: Review

    private var draftNames: [UUID: String] {
        Dictionary(meds.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
    }

    /// This person's current medications that the list doesn't mention.
    private var stopping: [Medication] {
        let kept = Set(meds.compactMap(\.existingID))
        let today = PregnancyMath.calendar.startOfDay(for: store.now)
        return store.medications.filter {
            $0.owner == owner && !kept.contains($0.id) && ($0.endDate.map { PregnancyMath.calendar.startOfDay(for: $0) >= today } ?? true)
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        ForEach(questions) { q in
            VStack(alignment: .leading, spacing: 12) {
                Label("One thing to check", systemImage: "questionmark.bubble.fill")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.peachDeep)
                Text(q.question)
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8) {
                    ForEach(q.options) { option in
                        Button {
                            Haptics.tap()
                            text += "\n" + option.clarification
                            questions = []
                            run()
                        } label: {
                            Text(option.label)
                                .font(.bloom(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.peachDeep)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Theme.surface, in: .capsule)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .bloomCard(fill: Theme.peachSoft)
        }

        section("Medications") {
            ForEach(meds) { med in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(med.shortName)
                            .font(.bloom(.headline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        let detail = [med.friendlyName.isEmpty ? nil : med.name, med.dose.isEmpty ? nil : med.dose,
                                      med.fixedTime.map { "at \($0.date(on: .now).formatted(date: .omitted, time: .shortened))" }]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.bloom(.subheadline))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(med.existingID == nil ? "New" : "Kept")
                        .font(.bloom(.caption, weight: .semibold))
                        .foregroundStyle(med.existingID == nil ? Theme.blushDeep : Theme.sageDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(med.existingID == nil ? Theme.blushSoft : Theme.sageSoft, in: .capsule)
                    Button {
                        Haptics.tap()
                        meds.removeAll { $0.id == med.id }
                        rules.removeAll { $0.involves(med.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Remove \(med.shortName)")
                }
                .padding(.vertical, 4)
            }
        }

        section("Rules") {
            if rules.isEmpty {
                Text("No timing rules. Each one is placed early in the day.")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(rules) { rule in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ScheduleEngine.describe(rule, names: draftNames))
                            .font(.bloom(.body, weight: .semibold))
                            .foregroundStyle(rule.isNoFood ? Theme.coralDeep : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !rule.sourceText.isEmpty {
                            Text("“\(rule.sourceText)”")
                                .font(.bloom(.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    Button {
                        Haptics.tap()
                        rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Remove rule")
                }
                .padding(.vertical, 4)
            }
        }

        if !stopping.isEmpty {
            section("Will be stopped") {
                Text(stopping.map(\.shortName).joined(separator: ", "))
                    .font(.bloom(.body, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Not in your list, so they stop from today. Their history stays.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
        }

        Toggle(isOn: $confirmed) {
            Text("This matches what my doctor or pharmacist told me")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .tint(Theme.sage)
        .bloomCard()
        .accessibilityIdentifier("meds-box-confirm")

        Button {
            save()
        } label: {
            Label("Plan my day", systemImage: "calendar.badge.clock")
        }
        .buttonStyle(BloomPrimaryButtonStyle())
        .disabled(!confirmed || meds.isEmpty)
        .accessibilityIdentifier("meds-box-save")

        Text("Bloom never suggests doses. Times come from your routine and the rules above.")
            .font(.bloom(.caption))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    // MARK: Done

    @ViewBuilder
    private var doneStep: some View {
        let template = store.activeTemplate(for: owner, on: store.now)
        let violations = template.map { store.violations(in: $0) } ?? self.violations
        VStack(alignment: .leading, spacing: 6) {
            Text(violations.isEmpty ? "All rules fit" : "Almost there")
                .font(.bloom(.largeTitle, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(violations.isEmpty ? "Every dose is at the earliest time that keeps all your rules." : "Some rules can't all fit in this routine. Here's which, with fixes that keep every rule.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(violations) { v in
            if let template {
                RuleProblemCard(template: template, violation: v)
            }
        }

        if let template {
            section("\(template.displayName) routine") {
                ForEach(template.doses.sorted { $0.time < $1.time }) { dose in
                    HStack {
                        Text(dose.time.date(on: .now).formatted(date: .omitted, time: .shortened))
                            .font(.bloom(.subheadline, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 76, alignment: .leading)
                        Text(store.medicationNames[dose.medicationID] ?? "")
                            .font(.bloom(.body, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                    }
                }
            }
        }

        if let onOpenSchedule {
            Button {
                onOpenSchedule()
            } label: {
                Label("Fine-tune the times", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(BloomSoftButtonStyle())
            .frame(maxWidth: .infinity)
        }
        Button("Done", action: onClose)
            .buttonStyle(BloomPrimaryButtonStyle())
            .accessibilityIdentifier("meds-box-done")
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.bloom(.caption, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.6)
            content()
        }
        .bloomCard()
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.bloom(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.coralDeep)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.coralSoft, in: .rect(cornerRadius: 18, style: .continuous))
    }

    // MARK: Logic

    private func go(_ next: Phase) {
        errorMessage = nil
        phase = next
    }

    private func prefill() {
        guard text.isEmpty else { return }
        let current = store.scheduledMedications(for: owner)
        let mine = store.rules(for: owner).map(\.sourceText).filter { !$0.isEmpty }
        if !mine.isEmpty {
            let names = current.map(\.shortName).joined(separator: ", ")
            text = "\(names).\n" + mine.joined(separator: ". ") + "."
        } else if !current.isEmpty || store.medications.contains(where: { $0.owner == owner }) {
            let all = store.medications.filter { $0.owner == owner && $0.endDate == nil }
            text = all.map(\.shortName).joined(separator: ", ") + (all.isEmpty ? "" : ". ")
        }
    }

    private func submit() {
        focused = false
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        if store.aiLookupConsent == true { run() } else { go(.consent) }
    }

    private func run() {
        phase = .parsing
        errorMessage = nil
        let input = text
        Task {
            do {
                let result = try await RegimenParseService.parse(text: input)
                meds = result.meds.map(matchExisting)
                rules = result.rules
                questions = result.questions
                confirmed = false
                Haptics.tap()
                phase = .review
            } catch {
                Haptics.warning()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't read that. Try rewording it."
                phase = .input
            }
        }
    }

    /// Same name as one of this person's medications → keep its id and history.
    private func matchExisting(_ draft: RegimenMedDraft) -> RegimenMedDraft {
        var d = draft
        let candidates = store.medications.filter { $0.owner == owner }
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let names = [norm(d.name), norm(d.friendlyName)].filter { !$0.isEmpty }
        let match = candidates.first { med in
            let theirs = [norm(med.name), norm(med.friendlyName)].filter { !$0.isEmpty }
            return names.contains { n in theirs.contains { $0 == n || $0.hasPrefix(n + " ") || n.hasPrefix($0 + " ") } }
        }
        d.existingID = match?.id
        return d
    }

    private func save() {
        guard confirmed, !meds.isEmpty else { return }
        violations = store.applyRegimen(owner: owner, meds: meds, rules: rules, confirmed: confirmed)
        if violations.isEmpty { Haptics.success() } else { Haptics.warning() }
        phase = .done
        Task {
            if await Permissions.notificationStatus() == .notDetermined {
                _ = await Permissions.requestNotifications()
                store.refreshReminders()
            }
        }
    }

    private func readLabel(_ image: UIImage) {
        isReadingLabel = true
        errorMessage = nil
        Task {
            defer { isReadingLabel = false }
            do {
                let lines = try await LabelOCR.lines(in: image)
                let profile = store.profile
                let names = [profile?.momName, profile?.partnerName, profile?.babyNickname].compactMap { $0 }
                let filtered = LabelTextFilter.filter(lines, personalNames: names)
                guard !filtered.kept.isEmpty else { throw LabelOCR.OCRError.noText }
                let joined = filtered.text.replacingOccurrences(of: "\n", with: " ")
                text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? joined : text + "\n" + joined
                Haptics.success()
            } catch {
                Haptics.warning()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the box. Try again with it flat and well lit, or type it in."
            }
        }
    }
}
