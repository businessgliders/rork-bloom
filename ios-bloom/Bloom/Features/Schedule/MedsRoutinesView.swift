import PhotosUI
import SwiftUI

/// Meds & routines, on one short screen:
/// routine chips → one row of day-anchor time cards → "Your meds & rules" (the only place to add,
/// change or remove meds) → "What Bloom understood", one line per rule with problems inline.
/// Lines are read one at a time (cached, in parallel, 600 ms after typing stops); the engine places every time.
struct MedsRoutinesView: View {
    var owner: MedOwner

    @Environment(AppStore.self) private var store

    @State private var text = ""
    @State private var loaded = false
    @State private var parser = LineParser()
    @State private var editor = MedsEditorController()
    @State private var query: EditorQuery?
    @State private var editorFocused = false
    @State private var lineCenters: [CGFloat] = []
    @State private var debounce: Task<Void, Never>?
    @State private var revision = 0
    @State private var confirmed = false
    @State private var justUpdated = false

    @State private var selectedRoutine: UUID?
    @State private var openCard: TimeCard?
    @State private var showQuiz = false
    @State private var renaming: ScheduleTemplate?
    @State private var renameText = ""
    @State private var daysFor: ScheduleTemplate?
    @State private var pendingDelete: ScheduleTemplate?
    @State private var sheetMed: Medication?

    private let placeholder = """
    One instruction per line, e.g.
    Thyroid as soon as I wake up, no food for 30 min after.
    Iron 4 hours after Thyroid.
    Prenatal with lunch.
    """

    // MARK: Derived

    private var templates: [ScheduleTemplate] { store.templates(for: owner) }
    private var routine: ScheduleTemplate? {
        templates.first { $0.id == selectedRoutine } ?? store.activeTemplate(for: owner, on: store.now) ?? templates.first
    }
    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }
    private var lines: [String] { RegimenAssembler.lines(of: text) }

    private var assembled: RegimenAssembler.Result {
        _ = revision
        var parses: [String: LineParse] = [:]
        for line in lines {
            let key = LineParseService.normalize(line)
            if let p = parser.cached(line) { parses[key] = p }
        }
        return RegimenAssembler.assemble(text: text, parses: parses, existing: store.existingForAssembler(owner))
    }

    /// Names offered above the keyboard and tinted in the text: her meds, then new names from her lines.
    private func names(_ result: RegimenAssembler.Result) -> [String] {
        var out = store.knownMedNames(owner)
        for d in result.drafts where !out.contains(where: { $0.caseInsensitiveCompare(d.shortName) == .orderedSame }) {
            out.append(d.shortName)
        }
        return out
    }

    private var allRead: Bool { _ = revision; return parser.isUpToDate(lines) }

    // MARK: Body

    var body: some View {
        let result = assembled
        let names = names(result)
        AdaptiveColumns {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    routineArea
                    editorCard(names)
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .duoListClearance()
        } secondary: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    consentCard
                    understoodSection(result)
                    confirmBar(result)
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .duoListClearance()
        } compact: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    routineArea
                    editorCard(names)
                    consentCard
                    understoodSection(result)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .duoListClearance()
            .background(BloomBackground())
            .safeAreaInset(edge: .bottom) {
                if !editorFocused {
                    confirmBar(result).padding(.horizontal, 16).padding(.bottom, 8).duoBarClearance()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editorFocused { suggestionBar(names).duoBarClearance() }
        }
        .navigationTitle(isViewer ? "Meds & routines" : "\(store.name(for: owner))'s meds & routines")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: openCard)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.scheduleChange?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: editorFocused)
        .onAppear(perform: load)
        .onDisappear {
            debounce?.cancel()
            store.saveMedsText(text, for: owner)
            if case .routine = store.scheduleChange?.placement { store.scheduleChange = nil }
        }
        .onChange(of: text) { _, _ in
            justUpdated = false
            scheduleParse()
        }
        .sheet(isPresented: $showQuiz) {
            RoutineQuizView(owner: owner, template: nil, days: nil) { saved in
                showQuiz = false
                if let saved { selectedRoutine = saved.id }
            }
        }
        .sheet(item: $daysFor) { t in
            RoutineDaysSheet(templateID: t.id, owner: owner)
                .presentationDetents([.height(300)])
        }
        .sheet(item: $sheetMed) { med in
            MedDetailsSheet(medication: med) { id, newOwner in move(id, to: newOwner) }
        }
        .alert("Rename routine", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if var t = renaming {
                    t.name = renameText.trimmingCharacters(in: .whitespaces)
                    store.saveTemplate(t, regenerate: false)
                    Haptics.select()
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete the \(pendingDelete?.displayName ?? "") routine?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                if let pendingDelete {
                    store.deleteTemplate(pendingDelete)
                    if selectedRoutine == pendingDelete.id { selectedRoutine = nil }
                }
                Haptics.warning()
                pendingDelete = nil
            }
        } message: {
            Text("Medications on those days won't have planned times until another routine covers them.")
        }
    }

    // MARK: Routine chips + time cards

    @ViewBuilder
    private var routineArea: some View {
        if let t = routine {
            VStack(alignment: .leading, spacing: 12) {
                routineChips(selected: t)
                timeCards(t)
                if let change = store.scheduleChange, change.placement == .routine(t.id) {
                    ScheduleChangePanel(change: change)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else {
            Button {
                Haptics.tap()
                showQuiz = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.peachDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up your routine")
                            .font(.bloom(.headline, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("When \(isViewer ? "you wake, eat and sleep" : "\(store.name(for: owner)) wakes, eats and sleeps"). Bloom places every dose around it.")
                            .font(.bloom(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .background(Theme.peachSoft, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("templates-new")
        }
    }

    private func routineChips(selected: ScheduleTemplate) -> some View {
        let todayID = store.activeTemplate(for: owner, on: store.now)?.id
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(templates) { t in
                    let on = t.id == selected.id
                    Button {
                        Haptics.select()
                        store.scheduleChange = nil
                        openCard = nil
                        selectedRoutine = t.id
                    } label: {
                        HStack(spacing: 5) {
                            if t.id == todayID {
                                Circle().fill(on ? Color.white : Theme.blushDeep).frame(width: 6, height: 6)
                                    .accessibilityLabel("Today")
                            }
                            Text(t.displayName)
                            if !store.violations(in: t).isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(on ? .white : Theme.coralDeep)
                                    .accessibilityLabel("A rule can't be met")
                            }
                        }
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(on ? .white : Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(on ? Theme.roseButton : Theme.surface, in: .capsule)
                        .overlay(Capsule().stroke(on ? .clear : Theme.ringTrack, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("routine-\(t.displayName)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityHint("Touch and hold to rename, change days, duplicate or delete.")
                    .contextMenu {
                        Button { renameText = t.displayName; renaming = t } label: { Label("Rename", systemImage: "pencil") }
                        Button { daysFor = t } label: {
                            Label("Change days · \(ScheduleTemplate.daysLabel(t.days))", systemImage: "calendar")
                        }
                        Button {
                            Haptics.success()
                            store.scheduleChange = nil
                            selectedRoutine = store.duplicateTemplate(t).id
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { pendingDelete = t } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                Button {
                    Haptics.tap()
                    showQuiz = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.blushDeep)
                        .frame(width: 36, height: 36)
                        .background(Theme.blushSoft, in: .circle)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("New routine")
                .accessibilityIdentifier("routine-add")
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    enum TimeCard: Hashable {
        case wake, bed, meal(UUID), addSnack
    }

    /// The routine with the pending change applied, so cards show what she just chose.
    private func shown(_ t: ScheduleTemplate) -> ScheduleTemplate {
        guard let change = store.scheduleChange, change.placement == .routine(t.id), let draft = change.draft else { return t }
        return draft
    }

    @ViewBuilder
    private func timeCards(_ original: ScheduleTemplate) -> some View {
        let t = shown(original)
        let meals = t.meals.sorted { $0.time < $1.time }
        let hasSnack = meals.contains { $0.name.caseInsensitiveCompare("Snack") == .orderedSame }
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        card(.wake, title: "Wake", icon: "sunrise.fill", tint: Theme.peachDeep, time: t.wake)
                        ForEach(meals) { meal in
                            card(.meal(meal.id), title: meal.name, icon: mealIcon(meal.name), tint: Theme.sageDeep, time: meal.time)
                                .contextMenu {
                                    if meal.name.caseInsensitiveCompare("Snack") == .orderedSame {
                                        Button(role: .destructive) {
                                            var e = t
                                            e.meals.removeAll { $0.id == meal.id }
                                            openCard = nil
                                            store.proposeRoutineChange(original: original, edited: e)
                                        } label: { Label("Remove snack", systemImage: "minus.circle") }
                                    }
                                }
                        }
                        if !hasSnack { snackCard(original: original, shown: t) }
                        card(.bed, title: "Bed", icon: "moon.fill", tint: Theme.blushDeep, time: t.bed)
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: openCard) { _, card in
                    if let card { withAnimation { proxy.scrollTo(card, anchor: .center) } }
                }
            }
            if let open = openCard, let time = time(of: open, in: t) {
                wheel(open, time: time, original: original, shown: t)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    private func mealIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "breakfast": "cup.and.saucer.fill"
        case "snack": "carrot.fill"
        default: "fork.knife"
        }
    }

    private func time(of card: TimeCard, in t: ScheduleTemplate) -> DoseTime? {
        switch card {
        case .wake: t.wake
        case .bed: t.bed
        case .meal(let id): t.meals.first { $0.id == id }?.time
        case .addSnack: nil
        }
    }

    private func card(_ kind: TimeCard, title: String, icon: String, tint: Color, time: DoseTime) -> some View {
        let open = openCard == kind
        let parts = clockParts(time)
        return Button {
            Haptics.select()
            openCard = open ? nil : kind
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(open ? .white : tint)
                    Text(title)
                        .font(.bloom(.caption, weight: .semibold))
                        .foregroundStyle(open ? .white : Theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts.0)
                        .font(.bloom(.title3, weight: .bold))
                        .monospacedDigit()
                    Text(parts.1)
                        .font(.bloom(.caption2, weight: .semibold))
                }
                .foregroundStyle(open ? .white : Theme.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 82, alignment: .leading)
            .background(open ? Theme.roseButton : Theme.surface, in: .rect(cornerRadius: 18, style: .continuous))
            .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(open ? 0.25 : 0.10), radius: 10, y: 4)
        }
        .buttonStyle(PressableStyle())
        .id(kind)
        .accessibilityLabel("\(title), \(ScheduleEngine.clock(time.minutesFromMidnight))")
        .accessibilityHint("Change the time")
        .accessibilityIdentifier("time-card-\(title)")
    }

    private func snackCard(original: ScheduleTemplate, shown t: ScheduleTemplate) -> some View {
        Button {
            Haptics.tap()
            var e = t
            let snack = ScheduleMeal(name: "Snack", time: DoseTime(hour: 15, minute: 30), durationMinutes: 15)
            e.meals.append(snack)
            store.proposeRoutineChange(original: original, edited: e)
            openCard = .meal(snack.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "carrot.fill").font(.system(size: 11, weight: .bold))
                    Text("Snack").font(.bloom(.caption, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
                Text("Add")
                    .font(.bloom(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.sageDeep)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 72, minHeight: 58, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.textSecondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        }
        .buttonStyle(PressableStyle())
        .id(TimeCard.addSnack)
        .accessibilityLabel("Add a snack (optional)")
        .accessibilityIdentifier("time-card-add-snack")
    }

    private func clockParts(_ time: DoseTime) -> (String, String) {
        let s = ScheduleEngine.clock(time.minutesFromMidnight)
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (s, "")
    }

    private func wheel(_ kind: TimeCard, time: DoseTime, original: ScheduleTemplate, shown t: ScheduleTemplate) -> some View {
        VStack(spacing: 0) {
            DatePicker("Time", selection: Binding(
                get: { time.date(on: .now) },
                set: { date in
                    let new = DoseTime(date: date)
                    guard new != time else { return }
                    var e = t
                    switch kind {
                    case .wake: e.wake = new
                    case .bed: e.bed = new
                    case .meal(let id):
                        if let i = e.meals.firstIndex(where: { $0.id == id }) { e.meals[i].time = new }
                    case .addSnack: return
                    }
                    store.proposeRoutineChange(original: original, edited: e)
                }
            ), displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 150)
            .clipped()
            .accessibilityIdentifier("time-wheel")
            Button("Done") {
                Haptics.select()
                openCard = nil
            }
            .font(.bloom(.subheadline, weight: .bold))
            .tint(Theme.blushDeep)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: .rect(cornerRadius: 22, style: .continuous))
    }

    // MARK: Editor

    private func editorCard(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your meds & rules")
                    .font(.bloom(.title3, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if !parser.reading.isEmpty {
                    Text("Reading…")
                        .font(.bloom(.caption, weight: .semibold))
                        .foregroundStyle(Theme.blushDeep)
                        .transition(.opacity)
                }
            }
            MedsTextEditor(
                text: $text,
                names: names,
                placeholder: placeholder,
                controller: editor,
                onQuery: { newQuery in
                    let wasHolding = query != nil
                    query = newQuery
                    if wasHolding && newQuery == nil { scheduleParse() }
                },
                onFocus: { editorFocused = $0 },
                onLineCenters: { lineCenters = $0 }
            )
            .frame(minHeight: 260)
            .background(Theme.surface, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topTrailing) { lineMarks }
            .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(0.12), radius: 16, y: 6)
            Text("One instruction per line. Type @ or the first letters of a med to pick its name.")
                .font(.bloom(.caption))
                .foregroundStyle(Theme.textSecondary)
        }
        .animation(.easeInOut(duration: 0.2), value: parser.reading)
    }

    /// Next to each line: a shimmer while it's being read, a soft check once understood, a warning if not.
    private var lineMarks: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(Array(lines.enumerated()), id: \.offset) { index, raw in
                let key = LineParseService.normalize(raw)
                if !key.isEmpty, index < lineCenters.count {
                    Group {
                        if parser.reading.contains(key) {
                            ShimmerPill()
                        } else if parser.failed[key] != nil {
                            Button {
                                Haptics.tap()
                                parser.forget(raw)
                                runParse()
                            } label: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.coralDeep)
                            }
                            .accessibilityLabel("Couldn't read this line. Try again")
                        } else if parser.cached(raw) != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.sage)
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityLabel("Understood")
                        }
                    }
                    .frame(width: 28, height: 20)
                    .offset(x: -8, y: lineCenters[index] - 10)
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func suggestionBar(_ names: [String]) -> some View {
        let matches = query.map { NameSuggestions.matches($0, in: names) } ?? []
        return HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if matches.isEmpty {
                        Button {
                            editor.insertMarker()
                        } label: {
                            Label("Pick a med", systemImage: "at")
                                .font(.bloom(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("suggest-at")
                    }
                    ForEach(matches, id: \.self) { name in
                        Button {
                            Haptics.select()
                            editor.insert(name)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pills.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(name)
                                    .font(.bloom(.subheadline, weight: .semibold))
                            }
                            .foregroundStyle(Theme.blushDeep)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.blushSoft, in: .capsule)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("suggest-\(name)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            // More names scroll in from the right: fade them out before Done instead of cutting them.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            }
            Rectangle()
                .fill(Theme.textSecondary.opacity(0.25))
                .frame(width: 1, height: 24)
            Button("Done") { editor.dismiss() }
                .font(.bloom(.subheadline, weight: .bold))
                .tint(Theme.blushDeep)
                .padding(.leading, 4)
                .padding(.trailing, 16)
                .accessibilityIdentifier("editor-done")
        }
        .frame(height: 50)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: matches)
    }

    // MARK: Consent

    @ViewBuilder
    private var consentCard: some View {
        if store.aiLookupConsent != true, !allRead, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Before Bloom reads your lines", systemImage: "hand.raised.fill")
                    .font(.bloom(.headline, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Bloom sends each line you write, and nothing else, to Rork's AI service, which passes it through Vercel AI Gateway to DeepSeek (Anthropic Claude if that's slow). It only sorts the line into medications and rules; the times are worked out on this iPhone. No photos, names or dates. Nothing changes until you tap Update plan.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Allow & read") {
                        Haptics.tap()
                        store.setAILookupConsent(true)
                        runParse()
                    }
                    .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.roseButton))
                    .accessibilityIdentifier("ai-consent-allow")
                    if store.aiLookupConsent == nil {
                        Button("Not now") { store.setAILookupConsent(false) }
                            .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary, fill: Theme.surfaceMuted))
                    }
                }
            }
            .bloomCard(fill: Theme.blushSoft, padding: 16)
        }
    }

    // MARK: What Bloom understood

    private func understoodSection(_ result: RegimenAssembler.Result) -> some View {
        let t = routine
        let violations = t.map { store.violations(in: $0) } ?? []
        let lineTexts = Set(result.lines.map(\.text))
        let orphans = violations.filter { !lineTexts.contains(LineParseService.normalize($0.rule.sourceText)) }
        let meds = store.currentMedications(for: owner)
        return VStack(alignment: .leading, spacing: 12) {
            Text("What Bloom understood")
                .font(.bloom(.title3, weight: .bold))
                .foregroundStyle(Theme.text)

            if !meds.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(meds) { med in
                            Button {
                                Haptics.tap()
                                sheetMed = med
                            } label: {
                                HStack(spacing: 6) {
                                    MedBadge(medication: med, size: 24, fill: med.paused ? Theme.surfaceMuted : Theme.blushSoft)
                                    Text(med.shortName)
                                        .font(.bloom(.subheadline, weight: .semibold))
                                        .foregroundStyle(med.paused ? Theme.textSecondary : Theme.text)
                                    if med.paused {
                                        Image(systemName: "pause.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 12)
                                .padding(.vertical, 4)
                                .background(Theme.surface, in: .capsule)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(med.paused ? "\(med.shortName), paused" : med.shortName)
                            .accessibilityHint("Name, photo and who takes it")
                            .accessibilityIdentifier("med-chip-\(med.shortName)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }

            if let t {
                ForEach(orphans) { v in RuleProblemCard(template: t, violation: v) }
            }

            VStack(alignment: .leading, spacing: 0) {
                let rows = understoodRows(result)
                if rows.isEmpty {
                    Text("Each line you write shows here as Bloom reads it.")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(14)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 14) }
                    understoodRow(row)
                    if let t, let summary = row.summary {
                        ForEach(violations.filter { LineParseService.normalize($0.rule.sourceText) == summary.text }) { v in
                            RuleProblemCard(template: t, violation: v)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                    }
                }
            }
            .background(Theme.surface.opacity(0.85), in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    private struct UnderstoodRow {
        var key: String
        var raw: String
        var summary: RegimenAssembler.LineSummary?
    }

    private func understoodRows(_ result: RegimenAssembler.Result) -> [UnderstoodRow] {
        lines.enumerated().compactMap { index, raw in
            let key = LineParseService.normalize(raw)
            guard !key.isEmpty else { return nil }
            return UnderstoodRow(key: key, raw: raw, summary: result.lines.first { $0.index == index })
        }
    }

    @ViewBuilder
    private func understoodRow(_ row: UnderstoodRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = row.summary {
                ForEach(summary.items, id: \.self) { item in
                    understoodItem(item)
                }
                if let problem = summary.problem {
                    Label(problem, systemImage: "questionmark.circle.fill")
                        .font(.bloom(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.peachDeep)
                    Text("“\(row.key)”")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            } else if parser.reading.contains(row.key) {
                HStack(spacing: 8) {
                    ShimmerPill()
                    Text(row.key)
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            } else if let failed = parser.failed[row.key] {
                Button {
                    parser.forget(row.raw)
                    runParse()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(failed, systemImage: "exclamationmark.circle.fill")
                            .font(.bloom(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.coralDeep)
                        Text("“\(row.key)”")
                            .font(.bloom(.caption))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(row.key)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Iron · at least 4 h after Thyroid": the med name in bold, the rule after it.
    private func understoodItem(_ item: String) -> some View {
        let parts = item.components(separatedBy: " · ")
        let isFood = item.contains("no food")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isFood ? "fork.knife" : "arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isFood ? Theme.coralDeep : Theme.textSecondary)
                .frame(width: 14)
            (Text(parts.first ?? "").fontWeight(.semibold).foregroundStyle(Theme.text)
             + Text(parts.count > 1 ? " · " + parts.dropFirst().joined(separator: " · ") : "").foregroundStyle(Theme.textSecondary))
                .font(.bloom(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Confirmation

    @ViewBuilder
    private func confirmBar(_ result: RegimenAssembler.Result) -> some View {
        let count = allRead ? store.pendingChangeCount(owner, assembled: result) : 0
        if justUpdated {
            Label("Plan updated", systemImage: "checkmark.circle.fill")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.sageDeep)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.sageSoft, in: .capsule)
                .frame(maxWidth: .infinity)
                .transition(.scale.combined(with: .opacity))
        } else if count > 0, !result.drafts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(count == 1 ? "1 change ready" : "\(count) changes ready")
                    .font(.bloom(.headline, weight: .bold))
                    .foregroundStyle(Theme.text)
                Toggle(isOn: $confirmed) {
                    Text("Matches my doctor or pharmacist")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                .tint(Theme.sageButton)
                .accessibilityIdentifier("meds-text-confirm")
                Button {
                    update(result)
                } label: {
                    Label("Update plan", systemImage: "calendar.badge.clock")
                        .font(.bloom(.headline, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.roseButton.opacity(confirmed ? 1 : 0.45), in: .capsule)
                }
                .buttonStyle(PressableStyle())
                .disabled(!confirmed)
                .accessibilityIdentifier("meds-text-update")
            }
            .padding(16)
            .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        text = store.medsTextOrFallback(for: owner)
        if selectedRoutine == nil { selectedRoutine = store.activeTemplate(for: owner, on: store.now)?.id }
        runParse()
    }

    private func scheduleParse() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.saveMedsText(text, for: owner)
            runParse()
        }
    }

    /// Reads changed lines only (the rest come from the cache), never cancelled by more typing.
    private func runParse() {
        guard store.aiLookupConsent == true else { revision += 1; return }
        var current = lines
        // While a name is half-typed (suggestions showing), hold that line back: the AI would guess at
        // "Calcium with pr". It is read once she picks a name, types on, or leaves the line.
        if let q = query, !NameSuggestions.matches(q, in: names(assembled)).isEmpty,
           let typing = editor.caretLine.map(LineParseService.normalize) {
            current.removeAll { LineParseService.normalize($0) == typing }
        }
        let known = store.knownMedNames(owner)
        Task {
            await parser.parse(lines: current, known: known)
            revision += 1
        }
    }

    private func update(_ result: RegimenAssembler.Result) {
        guard confirmed else { return }
        let found = store.applyText(owner, text: text, assembled: result, confirmed: true)
        if found.isEmpty { Haptics.success() } else { Haptics.warning() }
        confirmed = false
        justUpdated = true
        revision += 1
        Task {
            if await Permissions.notificationStatus() == .notDetermined {
                _ = await Permissions.requestNotifications()
                store.refreshReminders()
            }
            try? await Task.sleep(for: .seconds(2.5))
            justUpdated = false
        }
    }

    /// "Who takes it": the med and its lines move to the other person's text, then both plans are rebuilt.
    private func move(_ id: UUID, to newOwner: MedOwner) {
        let oldOwner = owner
        store.moveMedication(id, to: newOwner)
        text = store.medsTextOrFallback(for: oldOwner)
        Task {
            for who in [oldOwner, newOwner] {
                let body = store.medsTextOrFallback(for: who)
                let all = RegimenAssembler.lines(of: body)
                let parsed = await parser.parse(lines: all, known: store.knownMedNames(who))
                guard parser.isUpToDate(all) else { continue }
                let result = RegimenAssembler.assemble(text: body, parses: parsed, existing: store.existingForAssembler(who))
                store.applyText(who, text: body, assembled: result, confirmed: true)
            }
            revision += 1
        }
    }
}

// MARK: - Shimmer

/// A soft rose pill with light sweeping across it: this line is being read.
struct ShimmerPill: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Theme.blushSoft)
            .frame(width: 26, height: 12)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, Theme.blush.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width)
                }
                .clipShape(.capsule)
            }
            .onAppear {
                guard !reduceMotion else { phase = 0.2; return }
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
            .accessibilityLabel("Reading")
    }
}

// MARK: - Routine days

/// Long-press → Change days. A day belongs to one routine; picking another routine's day moves it.
private struct RoutineDaysSheet: View {
    var templateID: UUID
    var owner: MedOwner
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingMove: (day: Int, from: ScheduleTemplate)?

    var body: some View {
        if let t = store.templates.first(where: { $0.id == templateID }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(t.displayName) days")
                        .font(.bloom(.title3, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.bloom(.body, weight: .semibold))
                        .tint(Theme.blushDeep)
                }
                DayChips(days: t.days) { day in tap(day, in: t) }
                Text(pendingMove.map { "\(PregnancyMath.calendar.weekdaySymbols[$0.day]) follows \($0.from.displayName). Tap it again to move it here." }
                     ?? "A day follows one routine. Bloom keeps gap rules across midnight between them.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(pendingMove == nil ? Theme.textSecondary : Theme.peachDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(BloomBackground())
        }
    }

    private func tap(_ day: Int, in t: ScheduleTemplate) {
        Haptics.select()
        if t.days.contains(day) {
            var e = t
            e.days.remove(day)
            store.saveTemplate(e, regenerate: false)
            pendingMove = nil
        } else if let other = store.templates(for: owner).first(where: { $0.id != t.id && $0.days.contains(day) }) {
            if pendingMove?.day == day {
                store.moveDay(day, to: t)
                Haptics.success()
                pendingMove = nil
            } else {
                pendingMove = (day, other)
            }
        } else {
            store.moveDay(day, to: t)
        }
    }
}

// MARK: - Med sheet

/// Tapping a med: friendly name, photo, who takes it, "For me", pause. Times and rules live in the text.
struct MedDetailsSheet: View {
    var medication: Medication
    var onMove: (UUID, MedOwner) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var friendly = ""
    @State private var photo: String?
    @State private var owner: MedOwner = .mom
    @State private var follow: FollowMode = .live
    @State private var pickerItem: PhotosPickerItem?
    @State private var loaded = false

    private var current: Medication { store.medications.first { $0.id == medication.id } ?? medication }
    private var withPhoto: Medication {
        var m = current
        m.photoFilename = photo
        return m
    }
    private var hasPartner: Bool {
        store.isShared || !(store.profile?.partnerName.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        MedBadge(medication: withPhoto, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.name)
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.text)
                            if !current.dose.isEmpty {
                                Text(current.dose)
                                    .font(.bloom(.subheadline))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            HStack(spacing: 14) {
                                PhotosPicker(selection: $pickerItem, matching: .images) {
                                    Text(photo == nil ? "Add photo" : "Change photo")
                                }
                                if photo != nil {
                                    Button("Remove", role: .destructive) { photo = nil }
                                }
                            }
                            .font(.bloom(.subheadline, weight: .semibold))
                            .buttonStyle(.borderless)
                            .tint(Theme.blushDeep)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField(current.name, text: $friendly)
                        .accessibilityIdentifier("med-sheet-friendly")
                } header: {
                    Text("Friendly name")
                } footer: {
                    Text("Shown in the app, widgets and the Live Activity. Your text can use either name.")
                }

                if hasPartner {
                    Section("Who takes it") {
                        Picker("Who takes it", selection: $owner) {
                            ForEach(MedOwner.allCases) { role in
                                Text(store.pickerLabel(for: role)).tag(role)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if store.isShared {
                    Section {
                        Picker("For me", selection: $follow) {
                            ForEach(FollowMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                    } footer: {
                        Text("Only changes what this iPhone shows.")
                    }
                }

                Section {
                    if current.paused {
                        Button { Haptics.success(); store.resumeMedication(current) } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .tint(Theme.sageDeep)
                    } else {
                        Button { Haptics.tap(); store.stopMedication(current) } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .tint(Theme.peachDeep)
                    }
                } footer: {
                    Text(current.paused
                         ? "Paused from today. Its history and rules stay."
                         : "To change times or rules, edit its line in Your meds & rules.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BloomBackground())
            .navigationTitle(current.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).fontWeight(.semibold)
                        .accessibilityIdentifier("med-sheet-done")
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let saved = MedPhotoStore.save(image) {
                        photo = saved
                    }
                    pickerItem = nil
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                friendly = current.friendlyName
                photo = current.photoFilename
                owner = current.owner
                follow = store.followMode(for: current)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        var med = current
        med.friendlyName = friendly.trimmingCharacters(in: .whitespacesAndNewlines)
        med.photoFilename = photo
        store.upsertMedication(med, followMode: store.isShared ? follow : nil)
        if owner != med.owner { onMove(med.id, owner) }
        Haptics.success()
        dismiss()
    }
}
