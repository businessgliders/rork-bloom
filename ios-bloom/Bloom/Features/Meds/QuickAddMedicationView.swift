import PhotosUI
import SwiftUI
import UserNotifications

/// Quick add: type one line, scan the label or add a photo; the AI fills in a draft;
/// she checks a short review card and saves. The full form stays one tap away.
struct QuickAddMedicationView: View {
    var onClose: () -> Void

    @Environment(AppStore.self) private var store

    enum Phase: Equatable { case start, scanText, consent, parsing, followUp, review }

    @State private var phase: Phase = .start
    @State private var sentence = ""
    @State private var scanText = ""
    @State private var removedLines = 0
    @State private var fromScan = false
    @State private var isReadingLabel = false
    @State private var pendingText = ""
    @State private var errorMessage: String?
    @State private var draft = QuickDraft()
    @State private var followUp: MedFollowUp?
    @State private var customTime = DaySlot.morning.defaultTime.date(on: .now)
    @State private var photo: UIImage?
    @State private var showScanCamera = false
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var showScanPicker = false
    @State private var editor: ChipEditor?
    @State private var fullForm: FullFormSeed?
    @State private var chosenFollow: FollowMode?
    @FocusState private var sentenceFocused: Bool

    private let examples = [
        "Iron 1 tablet every morning, empty stomach",
        "Levothyroxine 75 mcg at 6:30am",
        "Prenatal vitamin with dinner",
    ]

    var body: some View {
        if let seed = fullForm {
            AddMedicationView(medication: nil, draft: seed.medication, draftPhoto: seed.photo, draftConfirmed: seed.confirmed, onClose: onClose)
        } else {
            NavigationStack {
                ZStack {
                    BloomBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch phase {
                            case .start: startStep
                            case .scanText: scanTextStep
                            case .consent: consentStep
                            case .parsing: parsingStep
                            case .followUp: followUpStep
                            case .review: reviewStep
                            }
                        }
                        .padding(20)
                        .padding(.bottom, 40)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        .id(phase)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose)
                    }
                    if phase != .start && phase != .parsing {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Start over") { go(.start) }
                                .tint(Theme.textSecondary)
                        }
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: phase)
                .sheet(item: $editor) { which in
                    ChipEditorSheet(editor: which, draft: $draft)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .fullScreenCover(isPresented: $showScanCamera) {
                    CameraCaptureView(purpose: .label) { image in
                        showScanCamera = false
                        readLabel(image)
                    } onCancel: {
                        showScanCamera = false
                    }
                }
                .onChange(of: scanPickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            readLabel(image)
                        }
                        scanPickerItem = nil
                    }
                }
            }
        }
    }

    private var title: String {
        switch phase {
        case .start, .consent, .parsing: "Add medication"
        case .scanText: "Check the label text"
        case .followUp: "One quick question"
        case .review: "Look right?"
        }
    }

    // MARK: Step 1 · Start

    @ViewBuilder
    private var startStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Just say it")
                .font(.bloom(.largeTitle, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text("Type it like you'd tell a friend. Bloom fills in the rest for you to check.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }

        VStack(alignment: .leading, spacing: 14) {
            TextField("e.g. \(examples[0])", text: $sentence, axis: .vertical)
                .font(.bloom(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2...5)
                .focused($sentenceFocused)
                .submitLabel(.go)
                .onSubmit { submit(sentence, scan: false) }
                // A vertical field turns Return into a newline; treat it as "Go" instead.
                .onChange(of: sentence) { _, newValue in
                    guard newValue.contains("\n") else { return }
                    sentence = newValue.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    sentenceFocused = false
                    if !sentence.isEmpty { submit(sentence, scan: false) }
                }
                .accessibilityIdentifier("quick-add-text")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(examples, id: \.self) { example in
                        Button {
                            Haptics.select()
                            sentence = example
                        } label: {
                            Text(example)
                                .font(.bloom(.caption, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.surfaceMuted, in: .capsule)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }

            Button {
                submit(sentence, scan: false)
            } label: {
                Label("Fill it in", systemImage: "sparkles")
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .disabled(sentence.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            .accessibilityIdentifier("quick-add-go")
        }
        .bloomCard()

        if let errorMessage { errorBanner(errorMessage) }

        HStack(spacing: 12) {
            Menu {
                Button("Use the camera", systemImage: "camera") {
                    Haptics.tap()
                    showScanCamera = true
                }
                // A PhotosPicker inside a Menu often fails to present; open it from a plain button instead.
                Button("Choose a photo of the label", systemImage: "photo.on.rectangle") {
                    Haptics.tap()
                    showScanPicker = true
                }
            } label: {
                startTile(
                    icon: "text.viewfinder",
                    title: isReadingLabel ? "Reading…" : "Scan the label",
                    subtitle: "Read on your iPhone",
                    tint: Theme.blushDeep,
                    fill: Theme.blushSoft,
                    busy: isReadingLabel
                )
            }
            .disabled(isReadingLabel)
            .photosPicker(isPresented: $showScanPicker, selection: $scanPickerItem, matching: .images)
            .accessibilityIdentifier("quick-add-scan")

            PhotoMenu(image: $photo) {
                startTile(
                    icon: photo == nil ? "camera.fill" : "checkmark.circle.fill",
                    title: photo == nil ? "Add a photo" : "Photo added",
                    subtitle: "Pill or box · optional",
                    tint: Theme.sageDeep,
                    fill: Theme.sageSoft,
                    thumbnail: photo
                )
            }
            .accessibilityIdentifier("quick-add-photo")
        }

        Label("Only text is sent to AI, never your photos. Bloom never suggests a dose.", systemImage: "lock.fill")
            .font(.bloom(.footnote))
            .foregroundStyle(Theme.textSecondary)

        Button {
            openFullForm(prefillName: true)
        } label: {
            Text("Fill in the full form instead")
                .font(.bloom(.subheadline, weight: .bold))
                .foregroundStyle(Theme.blushDeep)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private func startTile(icon: String, title: String, subtitle: String, tint: Color, fill: Color, busy: Bool = false, thumbnail: UIImage? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(.circle)
                } else if busy {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 44, height: 44)
            .background(fill, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bloom(.headline, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.bloom(.caption))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bloomCard(padding: 16)
    }

    // MARK: Scan text

    @ViewBuilder
    private var scanTextStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Here's what we read")
                .font(.bloom(.title, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text("Only this text is sent. Edit or delete anything you'd rather keep private.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }

        VStack(alignment: .leading, spacing: 12) {
            TextField("Label text", text: $scanText, axis: .vertical)
                .font(.bloom(.body, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(4...12)
                .accessibilityIdentifier("scan-text")
            if removedLines > 0 {
                Label("Removed \(removedLines) line\(removedLines == 1 ? "" : "s") with personal details (name, address, Rx number, pharmacy, doctor, dates).", systemImage: "eye.slash.fill")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.sageDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .bloomCard()

        if let errorMessage { errorBanner(errorMessage) }

        Button {
            submit(scanText, scan: true)
        } label: {
            Label("Use this text", systemImage: "sparkles")
        }
        .buttonStyle(BloomPrimaryButtonStyle())
        .disabled(scanText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        .accessibilityIdentifier("scan-use-text")

        HStack {
            Button("Scan again") {
                Haptics.tap()
                showScanCamera = true
            }
            .buttonStyle(BloomSoftButtonStyle())
            Spacer()
            PhotosPicker(selection: $scanPickerItem, matching: .images) {
                Text("Choose photo")
            }
            .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
        }
    }

    // MARK: Consent

    @ViewBuilder
    private var consentStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Before Bloom reads it", systemImage: "hand.raised.fill")
                .font(.bloom(.title3, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text("To fill this in, Bloom sends only this text to Rork's AI service, which passes it through Vercel AI Gateway to Google Gemini:")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("“\(pendingText)”")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(6)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: .rect(cornerRadius: 16, style: .continuous))
            Text("No photos, names or dates. Nothing is saved until you confirm it. You can turn this off any time in Settings.")
                .font(.bloom(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Allow & fill in") {
                    store.setAILookupConsent(true)
                    run(pendingText)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.blush))
                .accessibilityIdentifier("ai-consent-allow")
                Button("Fill in myself") {
                    openFullForm(prefillName: true)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
            }
        }
        .bloomCard(fill: Theme.blushSoft)
    }

    // MARK: Parsing

    private var parsingStep: some View {
        VStack(spacing: 18) {
            ZStack {
                BlobShape(seed: 5)
                    .fill(Theme.peachSoft)
                    .frame(width: 150, height: 140)
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(Theme.peachDeep)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Text("Reading it…")
                .font(.bloom(.title2, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(fromScan ? "Turning the label into a reminder." : "“\(pendingText)”")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Follow-up

    @ViewBuilder
    private var followUpStep: some View {
        if let followUp {
            HStack(spacing: 12) {
                MedBadge(medication: draft.previewMedication(photo: nil), size: 44)
                    .overlay { photoBadge(size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.shortName)
                        .font(.bloom(.headline, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    if !draft.dose.isEmpty {
                        Text(draft.dose)
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Text(followUp.question)
                    .font(.bloom(.title2, weight: .heavy))
                    .foregroundStyle(Theme.text)
                FlowLayout(spacing: 10) {
                    ForEach(followUp.options) { option in
                        Button {
                            chooseTimes(option.times)
                        } label: {
                            Text(option.label)
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.blushDeep)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(Theme.blushSoft, in: .capsule)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("followup-\(option.label)")
                    }
                }
                Divider()
                HStack {
                    DatePicker("Another time", selection: $customTime, displayedComponents: .hourAndMinute)
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Use") { chooseTimes([DoseTime(date: customTime)]) }
                        .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.blush))
                }
            }
            .bloomCard()
        }
    }

    // MARK: Step 3 · Review

    @ViewBuilder
    private var reviewStep: some View {
        // Name header
        HStack(alignment: .center, spacing: 14) {
            MedBadge(medication: draft.previewMedication(photo: nil), size: 64)
                .overlay { photoBadge(size: 64) }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Short name", text: $draft.friendlyName)
                    .font(.bloom(.title, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("review-friendly-name")
                if draft.fullName.caseInsensitiveCompare(draft.shortName) != .orderedSame {
                    Text(draft.fullName)
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }

        // Summary sentence, each part tappable
        VStack(alignment: .leading, spacing: 14) {
            FlowLayout(spacing: 6, lineSpacing: 8) {
                summaryChip(draft.shortName, editor: .name, suggested: false)
                dot
                if draft.dose.isEmpty {
                    summaryChip("add dose from your label", editor: .dose, suggested: false, missing: true)
                } else {
                    summaryChip(draft.dose, editor: .dose, suggested: false)
                }
                dot
                summaryChip(draft.scheduleText, editor: .schedule, suggested: draft.suggested.contains(.schedule))
                summaryChip(draft.timeText, editor: .time, suggested: draft.suggested.contains(.time))
                dot
                summaryChip(draft.foodText, editor: .food, suggested: draft.suggested.contains(.food))
                if let minutes = draft.minutesText {
                    dot
                    summaryChip(minutes, editor: .food, suggested: draft.suggested.contains(.minutes) || draft.suggested.contains(.food))
                }
            }
            if !draft.suggested.isEmpty {
                Label("Suggested parts are general info. Tap to check them against your label.", systemImage: "sparkles")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.peachDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .bloomCard()
        .accessibilityElement(children: .contain)

        // Who takes it
        VStack(alignment: .leading, spacing: 10) {
            Text("Who takes this?")
                .font(.bloom(.subheadline, weight: .heavy))
                .foregroundStyle(Theme.textSecondary)
            Picker("Who takes this?", selection: $draft.owner) {
                Text(momLabel).tag(MedOwner.mom)
                Text(partnerLabel).tag(MedOwner.partner)
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: draft.owner)

            if store.isShared {
                Text("For me")
                    .font(.bloom(.subheadline, weight: .heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
                Picker("For me", selection: Binding(get: { followMode }, set: { chosenFollow = $0 })) {
                    ForEach(FollowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: chosenFollow)
                Text(followMode == .live
                     ? "Live Activity, reminders and alerts on this phone."
                     : "In the app only. You can still log it.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .bloomCard(padding: 16)

        // Photo
        PhotoMenu(image: $photo) {
            HStack(spacing: 12) {
                Image(systemName: photo == nil ? "camera.fill" : "photo.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.sageDeep)
                    .frame(width: 40, height: 40)
                    .background(Theme.sageSoft, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(photo == nil ? "Add a photo" : "Change photo")
                        .font(.bloom(.headline, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(store.isShared ? "Pill or box, so it's easy to spot. Shared with your partner." : "Pill or box, so it's easy to spot. Stays on your iPhone.")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .bloomCard(padding: 14)
        }

        // Confirm + save
        Toggle(isOn: $draft.confirmed) {
            Text("This matches what my doctor or pharmacist told me")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .tint(Theme.sage)
        .bloomCard(padding: 16)
        .accessibilityIdentifier("review-confirm")

        Button(action: save) {
            Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(BloomPrimaryButtonStyle())
        .disabled(!draft.canSave)
        .accessibilityIdentifier("review-save")

        Button {
            fullForm = FullFormSeed(medication: draft.previewMedication(photo: nil), photo: photo, confirmed: draft.confirmed)
        } label: {
            Text("Edit details")
                .font(.bloom(.headline, weight: .bold))
                .foregroundStyle(Theme.blushDeep)
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("review-edit-details")

        Text("Bloom helps you remember. It doesn't give medical advice.")
            .font(.bloom(.footnote))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func photoBadge(size: CGFloat) -> some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
                .overlay(Circle().stroke(Theme.blushSoft, lineWidth: 3))
        }
    }

    private var dot: some View {
        Text("·")
            .font(.bloom(.title3, weight: .heavy))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 6)
    }

    private func summaryChip(_ text: String, editor which: ChipEditor, suggested: Bool, missing: Bool = false) -> some View {
        Button {
            Haptics.select()
            editor = which
        } label: {
            HStack(spacing: 4) {
                if suggested {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                }
                if missing {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                Text(text)
                    .font(.bloom(.headline, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(suggested ? Theme.peachDeep : (missing ? Theme.textSecondary : Theme.text))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if missing {
                    Capsule().strokeBorder(Theme.textSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                } else {
                    Capsule().fill(suggested ? Theme.peachSoft : Theme.surfaceMuted)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(suggested ? "\(text), suggested" : text)
        .accessibilityHint("Edit")
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.bubble.fill")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.coralDeep)
                .fixedSize(horizontal: false, vertical: true)
            Button("Fill in myself") { openFullForm(prefillName: true) }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.coralDeep, fill: Theme.surface))
        }
        .bloomCard(fill: Theme.coralSoft, padding: 16)
    }

    private var followMode: FollowMode { chosenFollow ?? store.defaultFollowMode(for: draft.owner) }

    private var momLabel: String {
        if store.isShared { return store.pickerLabel(for: .mom) }
        let name = store.profile?.momName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Mom" : name
    }

    private var partnerLabel: String {
        if store.isShared { return store.pickerLabel(for: .partner) }
        let name = store.profile?.partnerName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Partner" : name
    }

    // MARK: Actions

    private func go(_ next: Phase) {
        errorMessage = nil
        phase = next
    }

    private func submit(_ text: String, scan: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        sentenceFocused = false
        errorMessage = nil
        fromScan = scan
        pendingText = trimmed
        if store.aiLookupConsent == true {
            run(trimmed)
        } else {
            phase = .consent
        }
    }

    private func run(_ text: String) {
        phase = .parsing
        Task {
            do {
                let result = try await MedParseService.parse(text: text)
                draft = QuickDraft(result: result)
                followUp = result.followUp
                if let first = result.times.first { customTime = first.date(on: .now) }
                Haptics.tap()
                phase = result.followUp == nil ? .review : .followUp
            } catch {
                Haptics.warning()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't read that. Try rewording it, or fill it in yourself."
                phase = fromScan ? .scanText : .start
            }
        }
    }

    private func chooseTimes(_ times: [DoseTime]) {
        Haptics.success()
        draft.times = times.sorted()
        draft.suggested.remove(.time)
        phase = .review
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
                scanText = filtered.text
                removedLines = filtered.removedCount
                Haptics.success()
                phase = .scanText
            } catch {
                Haptics.warning()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the label. Try again with it flat and well lit, or type it in."
                if phase != .scanText { phase = .start }
            }
        }
    }

    private func openFullForm(prefillName: Bool) {
        Haptics.tap()
        let typed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = prefillName && typed.count <= 40 ? typed : ""
        fullForm = FullFormSeed(medication: Medication(name: name, dose: ""), photo: photo, confirmed: false)
    }

    private func save() {
        guard draft.canSave else { return }
        var med = draft.previewMedication(photo: nil)
        if let photo { med.photoFilename = MedPhotoStore.save(photo) }
        store.upsertMedication(med, followMode: store.isShared ? followMode : nil)
        Haptics.success()
        onClose()
        Task {
            if await Permissions.notificationStatus() == .notDetermined {
                _ = await Permissions.requestNotifications()
                store.refreshReminders()
            }
        }
    }
}

// MARK: - Draft

struct QuickDraft: Equatable {
    var fullName = ""
    var friendlyName = ""
    var emoji = "💊"
    var dose = ""
    var schedule: MedSchedule = .daily
    var times: [DoseTime] = [DaySlot.morning.defaultTime]
    var foodRule: FoodRule = .any
    var before = 0
    var after = 0
    var suggested: Set<MedField> = []
    var owner: MedOwner = .mom
    var confirmed = false

    init() {}

    init(result: MedParseResult) {
        fullName = result.fullName
        friendlyName = result.friendlyName.isEmpty ? result.fullName : result.friendlyName
        emoji = result.emoji
        dose = result.dose
        schedule = result.schedule
        times = result.times
        foodRule = result.foodRule
        before = result.noFoodBeforeMinutes
        after = result.noFoodAfterMinutes
        suggested = result.suggested
    }

    var shortName: String {
        let f = friendlyName.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? fullName : f
    }

    var canSave: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty && !times.isEmpty && confirmed
    }

    var scheduleText: String {
        switch schedule {
        case .daily: "every day"
        case .weekdays: schedule.summary
        }
    }

    var timeText: String {
        let list = times.sorted().map { $0.date(on: .now).formatted(date: .omitted, time: .shortened) }
        return "at " + ListFormatter.localizedString(byJoining: list)
    }

    var foodText: String {
        switch foodRule {
        case .any: "with or without food"
        case .withFood: "with food"
        case .emptyStomach: "empty stomach"
        }
    }

    var minutesText: String? {
        guard foodRule == .emptyStomach else { return nil }
        var parts: [String] = []
        if before > 0 { parts.append("\(Medication.durationText(before)) before") }
        if after > 0 { parts.append("\(Medication.durationText(after)) after") }
        return parts.isEmpty ? "no wait times" : "no food " + parts.joined(separator: ", ")
    }

    func previewMedication(photo filename: String?) -> Medication {
        let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let friendly = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Medication(
            name: full,
            friendlyName: friendly.caseInsensitiveCompare(full) == .orderedSame ? "" : friendly,
            owner: owner,
            photoFilename: filename,
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji,
            schedule: schedule,
            times: times.sorted(),
            foodRule: foodRule,
            noFoodBeforeMinutes: foodRule == .emptyStomach ? before : 0,
            noFoodAfterMinutes: foodRule == .emptyStomach ? after : 0
        )
    }
}

struct FullFormSeed: Equatable {
    var medication: Medication
    var photo: UIImage?
    var confirmed: Bool
}

// MARK: - Quick editors

enum ChipEditor: String, Identifiable {
    case name, dose, schedule, time, food
    var id: String { rawValue }
}

private struct ChipEditorSheet: View {
    var editor: ChipEditor
    @Binding var draft: QuickDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch editor {
                case .name: nameEditor
                case .dose: doseEditor
                case .schedule: scheduleEditor
                case .time: timeEditor
                case .food: foodEditor
                }
            }
            .font(.bloom(.body))
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Checking a suggested part confirms it.
                        switch editor {
                        case .schedule: draft.suggested.remove(.schedule)
                        case .time: draft.suggested.remove(.time)
                        case .food:
                            draft.suggested.remove(.food)
                            draft.suggested.remove(.minutes)
                        case .name, .dose: break
                        }
                        Haptics.tap()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private var navTitle: String {
        switch editor {
        case .name: "Name"
        case .dose: "Dose"
        case .schedule: "Which days"
        case .time: "Time"
        case .food: "Food"
        }
    }

    @ViewBuilder
    private var nameEditor: some View {
        Section {
            TextField("Short name, e.g. Iron", text: $draft.friendlyName)
                .font(.bloom(.title3, weight: .bold))
        } header: {
            Text("Shown everywhere")
        }
        Section {
            TextField("Full name from the label", text: $draft.fullName)
        } header: {
            Text("Full name")
        } footer: {
            Text("Shown in the medication's details.")
        }
        Section("Icon") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Medication.emojiChoices, id: \.self) { choice in
                        Button {
                            Haptics.select()
                            draft.emoji = choice
                        } label: {
                            Text(choice)
                                .font(.system(size: 24))
                                .frame(width: 44, height: 44)
                                .background(draft.emoji == choice ? Theme.blushSoft : Theme.surfaceMuted, in: .circle)
                                .overlay(Circle().stroke(draft.emoji == choice ? Theme.blush : .clear, lineWidth: 2))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Icon \(choice)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var doseEditor: some View {
        Section {
            TextField("e.g. 1 tablet, 75 mcg", text: $draft.dose)
                .font(.bloom(.title3, weight: .bold))
        } footer: {
            Text("Copy this from your prescription label. Bloom never suggests doses.")
        }
    }

    @ViewBuilder
    private var scheduleEditor: some View {
        let specific = Binding(
            get: { if case .weekdays = draft.schedule { return true } else { return false } },
            set: { on in draft.schedule = on ? .weekdays(Set(1...7)) : .daily }
        )
        Section {
            Picker("Schedule", selection: specific) {
                Text("Every day").tag(false)
                Text("Specific days").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if case .weekdays(let days) = draft.schedule {
                HStack(spacing: 6) {
                    ForEach(MedSchedule.weekdayOrder, id: \.self) { day in
                        let on = days.contains(day)
                        Button {
                            Haptics.select()
                            var next = days
                            if on { next.remove(day) } else { next.insert(day) }
                            draft.schedule = .weekdays(next)
                        } label: {
                            Text(PregnancyMath.calendar.veryShortWeekdaySymbols[day - 1])
                                .font(.bloom(.subheadline, weight: .bold))
                                .foregroundStyle(on ? .white : Theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(on ? Theme.blush : Theme.surfaceMuted, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PregnancyMath.calendar.weekdaySymbols[day - 1])
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timeEditor: some View {
        Section {
            ForEach(draft.times.indices, id: \.self) { index in
                HStack {
                    DatePicker(
                        "Dose \(index + 1)",
                        selection: Binding(
                            get: { draft.times[index].date(on: .now) },
                            set: { draft.times[index] = DoseTime(date: $0) }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    if draft.times.count > 1 {
                        Button(role: .destructive) {
                            draft.times.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove time")
                    }
                }
            }
            if draft.times.count < 4 {
                Button("Add a time", systemImage: "plus") {
                    let last = draft.times.max()?.hour ?? 8
                    draft.times.append(DoseTime(hour: min(last + 6, 22), minute: 0))
                }
            }
        } footer: {
            Text("Use the time on your prescription or the one your doctor gave you.")
        }
    }

    @ViewBuilder
    private var foodEditor: some View {
        Section {
            Picker("Food", selection: $draft.foodRule) {
                ForEach(FoodRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if draft.foodRule == .emptyStomach {
                Stepper(value: $draft.before, in: 0...240, step: 5) {
                    LabeledContent("No food before", value: draft.before == 0 ? "None" : Medication.durationText(draft.before))
                }
                Stepper(value: $draft.after, in: 0...240, step: 5) {
                    LabeledContent("No food after", value: draft.after == 0 ? "None" : Medication.durationText(draft.after))
                }
            }
        } footer: {
            Text("The pause after counts from when you actually take it.")
        }
    }
}

// MARK: - Photo menu

/// "Take photo / Choose from library / Remove" menu wrapped around any label.
struct PhotoMenu<Label: View>: View {
    @Binding var image: UIImage?
    @ViewBuilder var label: () -> Label

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showPicker = false

    var body: some View {
        Menu {
            Button("Take photo", systemImage: "camera") {
                Haptics.tap()
                showCamera = true
            }
            // A PhotosPicker inside a Menu often fails to present; open it from a plain button instead.
            Button("Choose from library", systemImage: "photo.on.rectangle") {
                Haptics.tap()
                showPicker = true
            }
            if image != nil {
                Button("Remove photo", systemImage: "trash", role: .destructive) { image = nil }
            }
        } label: {
            label()
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(purpose: .photo) { captured in
                image = captured
                showCamera = false
            } onCancel: {
                showCamera = false
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let loaded = UIImage(data: data) {
                    image = loaded.resizedToFit(maxDimension: 1600)
                    Haptics.success()
                }
                pickerItem = nil
            }
        }
    }
}

// MARK: - Flow layout

/// Wraps children onto new lines, like words in a sentence.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                var size = subviews[index].sizeThatFits(.unspecified)
                size.width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let current = rows.count - 1
            rows[current].width += (rows[current].indices.isEmpty ? 0 : spacing) + size.width
            rows[current].height = max(rows[current].height, size.height)
            rows[current].indices.append(index)
        }
        return rows
    }
}
