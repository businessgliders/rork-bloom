import PhotosUI
import SwiftUI

/// The meds & rules text editor: first setup, and later "Edit my meds & rules" (Meds & routines, Settings).
/// routine chips → one row of day-anchor time cards → "Your meds & rules" (the only place to add,
/// change or remove meds) → "What Bloom understood", one line per rule with problems inline.
/// A line without a med name belongs to the med on the nearest line above; a blank line is a break.
/// Lines are read one at a time (cached, in parallel, 600 ms after typing stops); the engine places every time.
struct MedsRoutinesView: View {
    var owner: MedOwner
    /// Opened from "Edit my meds & rules" (not first setup).
    var editing = false
    /// After "Update plan" (first setup flips to the overview; editing goes back).
    var onApplied: (() -> Void)? = nil

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
            PaneScroll(pane: .primary) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
                editorCard(names)
            }
        } secondary: {
            PaneScroll(pane: .secondary) {
                consentCard
                understoodSection(result)
                confirmBar(result)
            }
        } compact: {
            PaneScroll {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
                editorCard(names)
                consentCard
                understoodSection(result)
            }
            .background(BloomBackground())
            .safeAreaInset(edge: .bottom) {
                if !editorFocused {
                    compactConfirmBar(result).duoBarClearance()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editorFocused { suggestionBar(names).duoBarClearance() }
        }
        .navigationTitle(editing ? "Edit my meds & rules" : (isViewer ? "Meds & routines" : "\(store.name(for: owner))'s meds & routines"))
        .navigationBarTitleDisplayMode(.inline)
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
            MedDetailsSheet(medication: med) { id, newOwner in move(id, to: newOwner) }
        }
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
                                    .foregroundStyle(Theme.coralDeep)
                            }
                            .accessibilityLabel("Couldn't read this line. Try again")
                        } else if parser.resolved(lines)[index] != nil {
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
                Text("Bloom sends each line you write (with the lines just above it, so it knows which medication a line is about), and nothing else, to Rork's AI service, which passes it through Vercel AI Gateway to DeepSeek (Anthropic Claude if that's slow). It only sorts the line into medications and rules; the times are worked out on this iPhone. No photos, names or dates. Nothing changes until you tap Update plan.")
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
        var index: Int
        var key: String
        var raw: String
        var summary: RegimenAssembler.LineSummary?
    }

    private func understoodRows(_ result: RegimenAssembler.Result) -> [UnderstoodRow] {
        lines.enumerated().compactMap { index, raw in
            let key = LineParseService.normalize(raw)
            guard !key.isEmpty else { return nil }
            return UnderstoodRow(index: index, key: key, raw: raw, summary: result.lines.first { $0.index == index })
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
            } else if parser.isReading(index: row.index, in: lines) {
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

    /// Folded Duo and iPhone: one short row pinned at the bottom (space is reserved under the text),
    /// so it never covers what she's reading.
    @ViewBuilder
    private func compactConfirmBar(_ result: RegimenAssembler.Result) -> some View {
        let count = allRead ? store.pendingChangeCount(owner, assembled: result) : 0
        if justUpdated {
            Label("Plan updated", systemImage: "checkmark.circle.fill")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.sageDeep)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if count > 0, !result.drafts.isEmpty {
            HStack(spacing: 12) {
                Button {
                    Haptics.select()
                    confirmed.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: confirmed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(confirmed ? Theme.sageButton : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(count == 1 ? "1 change ready" : "\(count) changes ready")
                                .font(.bloom(.subheadline, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text("Matches my doctor or pharmacist")
                                .font(.bloom(.caption))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Matches my doctor or pharmacist")
                .accessibilityValue(confirmed ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("meds-text-confirm")
                Button {
                    update(result)
                } label: {
                    Text("Update plan")
                        .font(.bloom(.subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Theme.roseButton.opacity(confirmed ? 1 : 0.45), in: .capsule)
                }
                .buttonStyle(PressableStyle())
                .disabled(!confirmed)
                .accessibilityIdentifier("meds-text-update")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
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

    private func update(_ result: RegimenAssembler.Result) {
        guard confirmed else { return }
        let found = store.applyText(owner, text: text, assembled: result, confirmed: true)
        if found.isEmpty { Haptics.success() } else { Haptics.warning() }
        confirmed = false
        justUpdated = true
        revision += 1
        if let onApplied {
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                onApplied()
            }
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
