import PhotosUI
import SwiftUI

/// The meds & rules text editor: first setup, and later "Edit my meds & rules" (Meds & routines, Settings).
/// Boards 4 / 4b: routine chips → her text (the only place to add,
/// change or remove meds) → problems tied to her lines → "Update plan" with what would move.
/// A line without a med name belongs to the med on the nearest line above; a blank line is a break.
/// Lines are read one at a time (cached, in parallel, 600 ms after typing stops); the engine places every time.
struct MedsRoutinesView: View {
    var owner: MedOwner
    /// Opened from "Edit my meds & rules" (not first setup).
    var editing = false
    /// Open with the caret on the line that names this medication.
    var focusName: String? = nil
    /// After "Update plan" (first setup flips to the overview; editing goes back).
    var onApplied: (() -> Void)? = nil

    @Environment(AppStore.self) private var store

    @State private var text = ""
    @State private var loaded = false
    @State private var parser = LineParser()
    @State private var editor = MedsEditorController()
    @State private var query: EditorQuery?
    @State private var editorFocused = false
    @State private var debounce: Task<Void, Never>?
    @State private var revision = 0
    @State private var confirmed = false
    @State private var justUpdated = false

    @State private var selectedRoutine: UUID?
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
        return RegimenAssembler.assemble(text: text, lineParses: parser.resolved(lines), existing: store.existingForAssembler(owner))
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
            PaneScroll(pane: .primary, spacing: 14) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine, showTimeCards: !editing)
                editorCard(names)
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
        } secondary: {
            PaneScroll(pane: .secondary, spacing: 14) {
                consentCard
                problemsSection(result)
                if !editorFocused { updateBar(result, inline: true) }
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
        } compact: {
            PaneScroll(spacing: 14) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine, showTimeCards: !editing)
                editorCard(names)
                consentCard
                problemsSection(result)
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if !editorFocused { updateBar(result, inline: false).duoBarClearance() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editorFocused { suggestionBar(names).duoBarClearance() }
        }
        .navigationTitle(editing ? "My rules" : (isViewer ? "Meds & routines" : "\(store.name(for: owner))'s meds & routines"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editorFocused {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        Haptics.select()
                        editor.dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(Theme.rose)
                    .accessibilityIdentifier("editor-done")
                }
            }
        }
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
        .sheet(item: $sheetMed) { med in
            MedicationSheet(medication: med) { med in
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    editor.focus(lineNamed: med.shortName)
                }
            }
        }
    }


    // MARK: Editor

    private func editorCard(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !parser.reading.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.rose)
                    Text("Reading…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.rose)
                }
                .transition(.opacity)
            }
            // Each copy of the editor keeps its own line positions: the open iPhone Duo also lays out a hidden,
            // full-width copy of this pane, whose unwrapped lines put the marks below the visible ones.
            LineMeasured { report in
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
                onLineCenters: report,
                onNameTap: { name in
                    let lower = name.lowercased()
                    if let med = store.currentMedications(for: owner).first(where: {
                        $0.shortName.lowercased() == lower || $0.name.lowercased() == lower || $0.friendlyName.lowercased() == lower
                    }) {
                        Haptics.tap()
                        sheetMed = med
                    }
                }
            )
            .frame(minHeight: 260)
            .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
            } marks: { centers in
                lineMarks(centers)
            }
            Text(editorFocused
                 ? "Pick a name below, or keep typing a new one"
                 : "Tap anywhere in the text to change it. Tap a name to open that medication.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dayMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: parser.reading)
    }

    /// Next to each line: a shimmer while it's being read, a green check once understood, a warning if not.
    private func lineMarks(_ lineCenters: [CGFloat]) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(Array(lines.enumerated()), id: \.offset) { index, raw in
                let key = LineParseService.normalize(raw)
                if !key.isEmpty, index < lineCenters.count {
                    Group {
                        if parser.isReading(index: index, in: lines) {
                            ShimmerPill()
                        } else if parser.failed[key] != nil {
                            Button {
                                Haptics.tap()
                                parser.forget(raw)
                                runParse()
                            } label: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.terraDot)
                            }
                            .accessibilityLabel("Couldn't read this line. Try again")
                        } else if !editorFocused, parser.resolved(lines)[index] != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.greenCheck)
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

    /// "Your medications" above the keyboard; the best match for what she's typing is filled.
    private func suggestionBar(_ names: [String]) -> some View {
        let matches = query.map { NameSuggestions.matches($0, in: names) } ?? []
        let shown = query == nil ? names : matches
        let best = query == nil ? nil : matches.first
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Your medications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dayMuted)
                Spacer()
                // The Duo's side bar puts the toolbar's Done under the keyboard, so repeat it here.
                DuoBarOnly {
                    Button("Done") {
                        Haptics.select()
                        editor.dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .tint(Theme.rose)
                    .frame(minWidth: 44, minHeight: 32)
                    .accessibilityIdentifier("editor-done-bar")
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if shown.isEmpty {
                        Button {
                            editor.insertMarker()
                        } label: {
                            Label("Pick a med", systemImage: "at")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.daySecondary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                        }
                        .accessibilityIdentifier("suggest-at")
                    }
                    ForEach(shown, id: \.self) { name in
                        let isBest = name == best
                        Button {
                            Haptics.select()
                            editor.insert(name)
                        } label: {
                            Text(name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isBest ? .white : Theme.rose)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
                                .background(isBest ? Theme.rose : Theme.roseTint, in: .capsule)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("suggest-\(name)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Theme.dayCanvas)
        .overlay(alignment: .top) { Rectangle().fill(Theme.dayDivider).frame(height: 1) }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: shown)
    }

    // MARK: Consent

    @ViewBuilder
    private var consentCard: some View {
        if store.aiLookupConsent != true, !allRead, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Before Bloom reads your lines", systemImage: "hand.raised.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
                Text("Bloom sends each line you write (with the lines just above it, so it knows which medication a line is about), and nothing else, to Rork's AI service, which passes it through Vercel AI Gateway to DeepSeek (Anthropic Claude if that's slow). It only sorts the line into medications and rules; the times are worked out on this iPhone. No photos, names or dates. Nothing changes until you tap Update plan.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.daySecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Allow & read") {
                        Haptics.tap()
                        store.setAILookupConsent(true)
                        runParse()
                    }
                    .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.rose))
                    .accessibilityIdentifier("ai-consent-allow")
                    if store.aiLookupConsent == nil {
                        Button("Not now") { store.setAILookupConsent(false) }
                            .buttonStyle(BloomSoftButtonStyle(tint: Theme.daySecondary, fill: Theme.dayCard))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.roseTint, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        }
    }

    // MARK: Problems (tied to her lines)

    @ViewBuilder
    private func problemsSection(_ result: RegimenAssembler.Result) -> some View {
        let t = routine
        let violations = t.map { store.violations(in: $0) } ?? []
        let lineTexts = Set(result.lines.map(\.text))
        let orphans = violations.filter { !lineTexts.contains(LineParseService.normalize($0.rule.sourceText)) }
        let rows: [(index: Int, raw: String, key: String, problem: String?, failed: String?, broken: [RuleViolation])] =
            lines.enumerated().compactMap { index, raw in
                let key = LineParseService.normalize(raw)
                guard !key.isEmpty else { return nil }
                let summary = result.lines.first { $0.index == index }
                let broken = summary.map { s in violations.filter { LineParseService.normalize($0.rule.sourceText) == s.text } } ?? []
                let failed = parser.isReading(index: index, in: lines) ? nil : parser.failed[key]
                guard summary?.problem != nil || failed != nil || !broken.isEmpty else { return nil }
                return (index, raw, key, summary?.problem, failed, broken)
            }
        if !rows.isEmpty || !orphans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.index) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            Haptics.tap()
                            editor.focus(lineNamed: row.key, index: row.index)
                        } label: {
                            Text("Line \(row.index + 1) · “\(row.key)”")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.dayMuted)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if let problem = row.problem {
                            problemLine(problem)
                        }
                        if let failed = row.failed {
                            Button {
                                parser.forget(row.raw)
                                runParse()
                            } label: {
                                problemLine("\(failed) Tap to try again.")
                            }
                            .buttonStyle(.plain)
                        }
                        if let t {
                            ForEach(row.broken) { v in RuleProblemCard(template: t, violation: v) }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
                    .accessibilityIdentifier("line-problem-\(row.index + 1)")
                }
                if let t {
                    ForEach(orphans) { v in RuleProblemCard(template: t, violation: v) }
                }
            }
            .transition(.opacity)
        }
    }

    private func problemLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.terraDot).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.terraText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Update bar

    @ViewBuilder
    private func updateBar(_ result: RegimenAssembler.Result, inline: Bool) -> some View {
        let count = allRead ? store.pendingChangeCount(owner, assembled: result) : 0
        if count > 0, !result.drafts.isEmpty {
            let moves = store.previewTimeChanges(owner, assembled: result, routineID: routine?.id)
            VStack(alignment: .leading, spacing: 12) {
                changeSummary(count: count, moves: moves)
                Button {
                    Haptics.select()
                    confirmed.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: confirmed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(confirmed ? Theme.greenCheck : Theme.dayMuted)
                        Text("This matches what my doctor or pharmacist told me")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.dayText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This matches what my doctor or pharmacist told me")
                .accessibilityValue(confirmed ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("meds-text-confirm")
                Button {
                    update(result)
                } label: {
                    Text("Update plan")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.rose.opacity(confirmed ? 1 : 0.4), in: .capsule)
                }
                .buttonStyle(PressableStyle())
                .disabled(!confirmed)
                .accessibilityIdentifier("meds-text-update")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if inline {
                    RoundedRectangle(cornerRadius: Theme.dayRadius, style: .continuous).fill(Theme.dayCard)
                } else {
                    Rectangle().fill(Theme.dayCard).ignoresSafeArea(edges: .bottom)
                }
            }
            .overlay(alignment: .top) {
                if !inline { Rectangle().fill(Theme.dayDivider).frame(height: 1) }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if justUpdated {
            Label("Plan updated", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.greenText)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Theme.greenTint, in: .capsule)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .transition(.scale.combined(with: .opacity))
        } else if inline, allRead {
            // Wide layout only: keeps the side pane from looking empty when nothing is pending.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.greenCheck)
                Text("No changes to apply")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.dayRadius, style: .continuous).fill(Theme.dayCard))
            .accessibilityElement(children: .combine)
        }
    }

    /// "1 time change · Prenatal AM moves from 3:00 PM to 3:30 PM"
    private func changeSummary(count: Int, moves: [TextTimeChange]) -> some View {
        let head: String = {
            if moves.isEmpty { return count == 1 ? "1 change" : "\(count) changes" }
            return moves.count == 1 ? "1 time change" : "\(moves.count) time changes"
        }()
        let detail: String = {
            guard let first = moves.first else { return "No times move" }
            let line = "\(first.name) moves from \(ScheduleEngine.clock(first.from)) to \(ScheduleEngine.clock(first.to))"
            return moves.count > 1 ? "\(line), and \(moves.count - 1) more" : line
        }()
        return Text("\(Text(head).fontWeight(.semibold)) · \(detail)")
            .font(.system(size: 15))
            .monospacedDigit()
            .foregroundStyle(Theme.dayText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("meds-text-summary")
    }

    // MARK: Logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        text = store.medsTextOrFallback(for: owner)
        if selectedRoutine == nil { selectedRoutine = store.activeTemplate(for: owner, on: store.now)?.id }
        runParse()
        if let focusName {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                editor.focus(lineNamed: focusName)
            }
        }
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
        var holding: Set<String> = []
        if let q = query, !NameSuggestions.matches(q, in: names(assembled)).isEmpty,
           let typing = editor.caretLine.map(LineParseService.normalize), !typing.isEmpty {
            holding.insert(typing)
        }
        current = lines
        let known = store.knownMedNames(owner)
        Task {
            await parser.parse(lines: current, known: known, holding: holding)
            revision += 1
        }
    }

    /// Update plan: back to Meds & routines when every rule is kept; otherwise stay and explain under the lines.
    private func update(_ result: RegimenAssembler.Result) {
        guard confirmed else { return }
        let found = store.applyText(owner, text: text, assembled: result, confirmed: true)
        confirmed = false
        revision += 1
        if found.isEmpty {
            Haptics.success()
            justUpdated = true
            onApplied?()
        } else {
            Haptics.warning()
        }
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
                let result = RegimenAssembler.assemble(text: body, lineParses: parsed, existing: store.existingForAssembler(who))
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
struct RoutineDaysSheet: View {
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

/// The editor and the marks beside its lines, sharing line positions only with each other.
private struct LineMeasured<Content: View, Marks: View>: View {
    @ViewBuilder var content: (@escaping ([CGFloat]) -> Void) -> Content
    @ViewBuilder var marks: ([CGFloat]) -> Marks
    @State private var centers: [CGFloat] = []

    var body: some View {
        content { centers = $0 }
            .overlay(alignment: .topTrailing) { marks(centers) }
    }
}
