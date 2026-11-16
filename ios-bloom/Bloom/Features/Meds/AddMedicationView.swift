import SwiftUI
import UserNotifications

/// Add or edit a medication. Shown as a side panel on wide layouts and a sheet on phones.
struct AddMedicationView: View {
    var medication: Medication?
    var onClose: () -> Void

    @Environment(AppStore.self) private var store

    @State private var name: String
    @State private var friendlyName: String
    @State private var owner: MedOwner
    @State private var photo: UIImage?
    @State private var photoChanged = false
    @State private var dose: String
    @State private var emoji: String
    @State private var specificDays: Bool
    @State private var weekdays: Set<Int>
    @State private var enabledSlots: Set<DaySlot>
    @State private var slotTimes: [DaySlot: Date]
    @State private var foodRule: FoodRule
    @State private var before: Int
    @State private var after: Int
    @State private var notes: String
    @State private var confirmed: Bool

    @State private var showConsent = false
    @State private var lookupState: LookupState = .idle
    @State private var confirmDelete = false
    /// nil until the person picks; then the default follows "Who takes this?".
    @State private var chosenFollow: FollowMode?

    enum LookupState: Equatable {
        case idle
        case loading
        case suggestion(MedSuggestion)
        case failed(String)
    }

    /// - Parameters:
    ///   - medication: the medication to edit, or nil to add a new one.
    ///   - draft: prefilled values for a new medication (from quick add).
    init(
        medication: Medication?,
        draft: Medication? = nil,
        draftPhoto: UIImage? = nil,
        draftConfirmed: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.medication = medication
        self.onClose = onClose
        let med = medication ?? draft
        _name = State(initialValue: med?.name ?? "")
        _friendlyName = State(initialValue: med?.friendlyName ?? "")
        _owner = State(initialValue: med?.owner ?? .mom)
        if let draftPhoto {
            _photo = State(initialValue: draftPhoto)
            _photoChanged = State(initialValue: true)
        } else {
            _photo = State(initialValue: medication?.photoFilename.flatMap(MedPhotoStore.image))
        }
        _dose = State(initialValue: med?.dose ?? "")
        _emoji = State(initialValue: med?.emoji ?? "💊")
        switch med?.schedule ?? .daily {
        case .daily:
            _specificDays = State(initialValue: false)
            _weekdays = State(initialValue: Set(1...7))
        case .weekdays(let days):
            _specificDays = State(initialValue: true)
            _weekdays = State(initialValue: days)
        }
        var slots = Set<DaySlot>()
        var times: [DaySlot: Date] = [:]
        for slot in DaySlot.allCases { times[slot] = slot.defaultTime.date(on: .now) }
        for time in med?.times ?? [] where !slots.contains(time.slot) {
            slots.insert(time.slot)
            times[time.slot] = time.date(on: .now)
        }
        if med == nil || slots.isEmpty { slots = [.morning] }
        _enabledSlots = State(initialValue: slots)
        _slotTimes = State(initialValue: times)
        _foodRule = State(initialValue: med?.foodRule ?? .any)
        _before = State(initialValue: med?.noFoodBeforeMinutes ?? 0)
        _after = State(initialValue: med?.noFoodAfterMinutes ?? 0)
        _notes = State(initialValue: med?.notes ?? "")
        _confirmed = State(initialValue: medication != nil || draftConfirmed)
    }

    private var isEditing: Bool { medication != nil }
    /// Placed by a routine: times and food come from the rules, not from this form.
    private var isManaged: Bool { medication?.managed == true }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && (isManaged || !enabledSlots.isEmpty) && confirmed && (isManaged || !specificDays || !weekdays.isEmpty)
    }
    private var isStopped: Bool {
        guard let end = medication?.endDate else { return false }
        return end < PregnancyMath.calendar.startOfDay(for: .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                followSection
                if showConsent { consentSection }
                lookupSection
                doseSection
                if isManaged {
                    managedSection
                } else {
                    scheduleSection
                    foodSection
                }
                notesSection
                confirmSection
                if isEditing { manageSection }
            }
            .font(.bloom(.body))
            .scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit medication" : "Add medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(!canSave)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: lookupState)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showConsent)
            .confirmationDialog("Delete \(trimmedName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete medication and history", role: .destructive) {
                    if let medication { store.deleteMedication(medication) }
                    onClose()
                }
            } message: {
                Text("This removes the medication and every dose you logged for it. To keep your history, choose Stop taking instead.")
            }
        }
    }

    // MARK: Sections

    /// Routine medications: show today's time and the rules; changes happen in Routines.
    private var managedSection: some View {
        Section {
            let times = medication?.plannedTimes(on: store.now) ?? []
            LabeledContent("Today", value: times.isEmpty ? "Not planned" : times.map { ScheduleEngine.clock($0.minutesFromMidnight) }.joined(separator: ", "))
            ForEach(store.rules.filter { $0.subjectID == medication?.id }) { rule in
                Text(store.describe(rule))
                    .font(.bloom(.subheadline))
                    .foregroundStyle(rule.isNoFood ? Theme.coralDeep : Theme.textSecondary)
            }
        } header: {
            Text("Time & rules")
        } footer: {
            Text("Carry places this around your routine. To change its rules, use Edit medications & rules; to move it, open the routine.")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Name, e.g. Levothyroxine", text: $name)
                .font(.bloom(.title3, weight: .bold))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onChange(of: name) { _, _ in
                    if case .suggestion = lookupState { lookupState = .idle }
                    if case .failed = lookupState { lookupState = .idle }
                }

            TextField("Short name (optional), e.g. Thyroid", text: $friendlyName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("friendly-name")

            PhotoMenu(image: Binding(get: { photo }, set: { photo = $0; photoChanged = true })) {
                HStack(spacing: 12) {
                    ZStack {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFill()
                        } else {
                            Text(emoji).font(.system(size: 22))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(Theme.blushSoft, in: .circle)
                    .clipShape(.circle)
                    Text(photo == nil ? "Add a photo of the pill or box" : "Change photo")
                        .font(.bloom(.body, weight: .semibold))
                        .foregroundStyle(Theme.blushDeep)
                    Spacer(minLength: 0)
                }
            }

            Picker("Who takes this?", selection: $owner) {
                Text(store.pickerLabel(for: .mom)).tag(MedOwner.mom)
                Text(store.pickerLabel(for: .partner)).tag(MedOwner.partner)
            }
            .disabled(isManaged)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Medication.emojiChoices, id: \.self) { choice in
                        Button {
                            Haptics.select()
                            emoji = choice
                        } label: {
                            Text(choice)
                                .font(.system(size: 24))
                                .frame(width: 44, height: 44)
                                .background(emoji == choice ? Theme.blushSoft : Theme.surfaceMuted, in: .circle)
                                .overlay(Circle().stroke(emoji == choice ? Theme.blush : .clear, lineWidth: 2))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Icon \(choice)")
                        .accessibilityAddTraits(emoji == choice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            Button {
                startLookup()
            } label: {
                HStack {
                    Label("Suggest timing", systemImage: "sparkles")
                        .font(.bloom(.headline, weight: .bold))
                    Spacer()
                    if lookupState == .loading { CarrySpinner(size: 20) }
                }
            }
            .disabled(trimmedName.count < 2 || lookupState == .loading)
        } header: {
            Text("Medication")
        } footer: {
            Text(store.isShared
                 ? "The short name shows everywhere; the full name stays in the details. Photos are shared with your partner. Suggestions cover general timing and food only, never doses."
                 : "The short name shows everywhere; the full name stays in the details. Photos stay on your iPhone. Suggestions cover general timing and food only, never doses.")
        }
    }

    private var followMode: FollowMode {
        chosenFollow ?? (medication.map { store.followMode(for: $0) }.flatMap { mode in
            medication?.owner == owner ? mode : nil
        } ?? store.defaultFollowMode(for: owner))
    }

    @ViewBuilder
    private var followSection: some View {
        if store.isShared {
            Section {
                Picker("For me", selection: Binding(get: { followMode }, set: { chosenFollow = $0 })) {
                    ForEach(FollowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .sensoryFeedback(.selection, trigger: chosenFollow)
            } header: {
                Text("For me")
            } footer: {
                Text(followMode == .live
                     ? "This phone shows the Live Activity, reminders and \(owner == store.viewerRole ? "" : "\(store.name(for: owner))'s ")dose alerts for this medication."
                     : "It stays in the app and you can still log it, but this phone won't show a Live Activity, reminders or alerts for it.")
            }
        }
    }

    private var consentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Before we look it up", systemImage: "hand.raised.fill")
                    .font(.bloom(.headline, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text("To suggest timing, Carry sends only the medication name you typed (\"\(trimmedName)\") to Rork's AI service, which passes it through Vercel AI Gateway to Google Gemini. Nothing else (no names, dates or doses) is sent, and nothing is saved unless you confirm it.")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can turn this off any time in Settings.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    Button("Allow & suggest") {
                        store.setAILookupConsent(true)
                        showConsent = false
                        runLookup()
                    }
                    .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.roseButton))
                    Button("Not now") {
                        store.setAILookupConsent(false)
                        showConsent = false
                    }
                    .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.blushSoft)
    }

    @ViewBuilder
    private var lookupSection: some View {
        switch lookupState {
        case .idle, .loading:
            EmptyView()
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.bubble")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .suggestion(let suggestion):
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Suggested. Confirm with your doctor or pharmacist.", systemImage: "sparkles")
                        .font(.bloom(.subheadline, weight: .heavy))
                        .foregroundStyle(Theme.peachDeep)
                    if suggestion.recognized {
                        Text(suggestion.kind.isEmpty ? suggestion.displayName : "\(suggestion.displayName) · \(suggestion.kind)")
                            .font(.bloom(.headline, weight: .bold))
                            .foregroundStyle(Theme.text)
                        suggestionLine("fork.knife", suggestionFoodText(suggestion))
                        if let slot = suggestion.preferredSlot {
                            suggestionLine(slot.symbol, "Usually taken in the \(slot.title.lowercased())")
                        }
                        if !suggestion.tip.isEmpty {
                            suggestionLine("lightbulb", suggestion.tip)
                        }
                        Button("Use these suggestions") { apply(suggestion) }
                            .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.peachButton))
                            .padding(.top, 4)
                    } else {
                        Text("We couldn't find general information for this name. Please fill it in from your prescription label.")
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Theme.peachSoft)
        }
    }

    private func suggestionLine(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.peachDeep)
        }
        .font(.bloom(.subheadline))
        .foregroundStyle(Theme.text)
    }

    private func suggestionFoodText(_ s: MedSuggestion) -> String {
        switch s.foodRule {
        case .any: return "With or without food"
        case .withFood: return "Take with food"
        case .emptyStomach:
            var parts: [String] = []
            if s.noFoodBeforeMinutes > 0 { parts.append("\(Medication.durationText(s.noFoodBeforeMinutes)) before") }
            if s.noFoodAfterMinutes > 0 { parts.append("\(Medication.durationText(s.noFoodAfterMinutes)) after") }
            return parts.isEmpty ? "Empty stomach" : "Empty stomach · no food " + parts.joined(separator: ", ")
        }
    }

    private var doseSection: some View {
        Section {
            TextField("e.g. 1 tablet, 75 mcg", text: $dose)
        } header: {
            Text("Dose")
        } footer: {
            Text("Copy this from your prescription label. Carry never suggests doses.")
        }
    }

    private var scheduleSection: some View {
        Section("When") {
            Picker("Schedule", selection: $specificDays) {
                Text("Every day").tag(false)
                Text("Specific days").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if specificDays {
                HStack(spacing: 6) {
                    ForEach(MedSchedule.weekdayOrder, id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button {
                            Haptics.select()
                            if on { weekdays.remove(day) } else { weekdays.insert(day) }
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

            ForEach(DaySlot.allCases) { slot in
                slotRow(slot)
            }
        }
    }

    private func slotRow(_ slot: DaySlot) -> some View {
        let isOn = Binding(
            get: { enabledSlots.contains(slot) },
            set: { on in
                Haptics.select()
                if on { enabledSlots.insert(slot) } else { enabledSlots.remove(slot) }
            }
        )
        let time = Binding(
            get: { slotTimes[slot] ?? slot.defaultTime.date(on: .now) },
            set: { slotTimes[slot] = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Label(slot.title, systemImage: slot.symbol)
                    .font(.bloom(.body, weight: .semibold))
            }
            .tint(Theme.blush)
            if isOn.wrappedValue {
                DatePicker("Time", selection: time, in: slotRange(slot), displayedComponents: .hourAndMinute)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func slotRange(_ slot: DaySlot) -> ClosedRange<Date> {
        let cal = PregnancyMath.calendar
        let day = cal.startOfDay(for: .now)
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }
        switch slot {
        case .morning: return at(0, 0)...at(11, 59)
        case .afternoon: return at(12, 0)...at(16, 59)
        case .evening: return at(17, 0)...at(23, 59)
        }
    }

    private var foodSection: some View {
        Section {
            Picker("Food", selection: $foodRule) {
                ForEach(FoodRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if foodRule == .emptyStomach {
                Stepper(value: $before, in: 0...240, step: 5) {
                    LabeledContent("No food before", value: before == 0 ? "None" : Medication.durationText(before))
                }
                Stepper(value: $after, in: 0...240, step: 5) {
                    LabeledContent("No food after", value: after == 0 ? "None" : Medication.durationText(after))
                }
            }
        } header: {
            Text("Food")
        } footer: {
            if foodRule == .emptyStomach {
                Text("The pause after counts from when you actually take it, so a late dose moves your next meal too.")
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Anything to remember (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var confirmSection: some View {
        Section {
            Toggle(isOn: $confirmed) {
                Text("This matches what my doctor or pharmacist told me")
                    .font(.bloom(.subheadline, weight: .semibold))
            }
            .tint(Theme.sage)
        } footer: {
            Text("Carry helps you remember. It doesn't give medical advice.")
        }
    }

    private var manageSection: some View {
        Section {
            if let medication {
                if isStopped {
                    Button("Start taking again") {
                        store.resumeMedication(medication)
                        Haptics.success()
                        onClose()
                    }
                } else {
                    Button("Stop taking (keeps history)") {
                        store.stopMedication(medication)
                        Haptics.tap()
                        onClose()
                    }
                }
                Button("Delete medication", role: .destructive) { confirmDelete = true }
            }
        }
    }

    // MARK: Actions

    private func startLookup() {
        if store.aiLookupConsent == true {
            runLookup()
        } else {
            showConsent = true
        }
    }

    private func runLookup() {
        let query = trimmedName
        guard !query.isEmpty else { return }
        lookupState = .loading
        Task {
            do {
                let suggestion = try await MedLookupService.lookup(name: query)
                guard trimmedName == query else { return }
                lookupState = .suggestion(suggestion)
                Haptics.tap()
            } catch {
                lookupState = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't get a suggestion. You can fill it in yourself.")
            }
        }
    }

    private func apply(_ suggestion: MedSuggestion) {
        Haptics.success()
        withAnimation {
            foodRule = suggestion.foodRule
            before = suggestion.noFoodBeforeMinutes
            after = suggestion.noFoodAfterMinutes
            if let slot = suggestion.preferredSlot, enabledSlots.count <= 1 {
                enabledSlots = [slot]
            }
            lookupState = .idle
        }
    }

    private func save() {
        guard canSave else { return }
        var med = medication ?? Medication(name: trimmedName, dose: "")
        med.name = trimmedName
        let friendly = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        med.friendlyName = friendly.caseInsensitiveCompare(trimmedName) == .orderedSame ? "" : friendly
        med.owner = owner
        if photoChanged {
            med.photoFilename = photo.flatMap(MedPhotoStore.save)
        }
        med.dose = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        med.emoji = emoji
        if !med.managed {
            med.schedule = specificDays && weekdays.count < 7 ? .weekdays(weekdays) : .daily
            med.times = enabledSlots.sorted().map { DoseTime(date: slotTimes[$0] ?? $0.defaultTime.date(on: .now)) }
            med.foodRule = foodRule
            med.noFoodBeforeMinutes = foodRule == .emptyStomach ? before : 0
            med.noFoodAfterMinutes = foodRule == .emptyStomach ? after : 0
        }
        med.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
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
