import SwiftUI
import UniformTypeIdentifiers

/// Meds & routines once a plan exists: routine chips and time cards, a timeline she can drag doses on,
/// then one card per medication in her order with its rules as rows she can change in place.
/// The full text editor only comes back from Settings → "Start over from text".
struct MedsScheduleContainer: View {
    var owner: MedOwner
    @Environment(AppStore.self) private var store
    @State private var setup: Bool?

    var body: some View {
        Group {
            if setup == true {
                MedsRoutinesView(owner: owner, onApplied: {
                    withAnimation(.smooth(duration: 0.4)) { setup = false }
                })
            } else if setup == false {
                MedsPlanView(owner: owner)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if setup == nil { setup = !store.currentMedications(for: owner).contains { $0.managed } }
        }
    }
}

struct MedsPlanView: View {
    var owner: MedOwner
    @Environment(AppStore.self) private var store

    @State private var selectedRoutine: UUID?
    @State private var order: [UUID] = []
    @State private var dragging: UUID?
    @State private var sheetMed: Medication?
    @State private var showAddMedication = false
    @State private var parser = LineParser()

    private var templates: [ScheduleTemplate] { store.templates(for: owner) }
    private var routine: ScheduleTemplate? {
        templates.first { $0.id == selectedRoutine } ?? store.activeTemplate(for: owner, on: store.now) ?? templates.first
    }
    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }

    private var meds: [Medication] {
        let list = store.currentMedications(for: owner).filter(\.managed)
        guard !order.isEmpty else { return list }
        return list.sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
    }

    var body: some View {
        AdaptiveColumns {
            PaneScroll(pane: .primary) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
                timelineSection
            }
        } secondary: {
            PaneScroll(pane: .secondary, spacing: 14) {
                medsSection
            }
        } compact: {
            PaneScroll(spacing: 18) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
                timelineSection
                medsSection
            }
            .background(BloomBackground())
        }
        .navigationTitle(isViewer ? "Meds & routines" : "\(store.name(for: owner))'s meds & routines")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.scheduleChange?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: meds.map(\.id))
        .onAppear {
            if selectedRoutine == nil { selectedRoutine = store.activeTemplate(for: owner, on: store.now)?.id }
        }
        .onDisappear {
            switch store.scheduleChange?.placement {
            case .routine, .medication: store.scheduleChange = nil
            default: break
            }
        }
        .sheet(item: $sheetMed) { med in
            MedDetailsSheet(medication: med) { id, newOwner in
                store.moveMedication(id, to: newOwner)
                Task { await reapplyText(for: [owner, newOwner]) }
            }
        }
        .sheet(isPresented: $showAddMedication) {
            AddMedicationPromptSheet(owner: owner, parser: parser) { id in
                showAddMedication = false
                guard let id else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    store.proposeDayChange(owner: owner, day: store.now, edit: .review, placement: .medication(id))
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineSection: some View {
        if let t = routine, !meds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your day")
                        .font(.bloom(.title3, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("Drag a medication to move it")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
                PlanTimeline(template: t, meds: meds.filter { !$0.paused }, times: shownTimes(t))
            }
            .bloomCard(fill: Theme.surface.opacity(0.9), padding: 16)
        }
    }

    /// A pending routine or rule edit's times, else the routine's own.
    private func shownTimes(_ t: ScheduleTemplate) -> [UUID: Int] {
        if let change = store.scheduleChange, change.templateID == t.id, change.kind == .routine || change.kind == .rule {
            return change.times
        }
        return Dictionary(t.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Medications

    @ViewBuilder
    private var medsSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Your medications")
                .font(.bloom(.title3, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("Hold and drag to reorder")
                .font(.bloom(.caption))
                .foregroundStyle(Theme.textSecondary)
        }
        if let t = routine {
            let list = meds
            let times = shownTimes(t)
            ForEach(Array(list.enumerated()), id: \.element.id) { index, med in
                MedPlanCard(
                    medication: med, owner: owner, template: t, time: times[med.id],
                    pinned: t.dose(for: med.id)?.pinned == true,
                    canMoveUp: index > 0, canMoveDown: index < list.count - 1,
                    parser: parser,
                    onOpen: { sheetMed = med },
                    onMove: { up in move(med.id, up: up) }
                )
                .opacity(dragging == med.id ? 0.55 : 1)
                .onDrag {
                    dragging = med.id
                    Haptics.select()
                    return NSItemProvider(object: med.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: MedReorderDelegate(target: med.id, order: $order, dragging: $dragging,
                                                                   current: list.map(\.id)) { ids in
                    store.reorderMedications(owner, ids: ids)
                })
            }
        } else {
            Text("Set up a routine above, then Bloom places every dose around it.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        Button {
            Haptics.tap()
            showAddMedication = true
        } label: {
            Label("Add a medication", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BloomSoftButtonStyle())
        .accessibilityIdentifier("plan-add-medication")
    }

    private func move(_ id: UUID, up: Bool) {
        var ids = meds.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        order = ids
        Haptics.select()
        store.reorderMedications(owner, ids: ids)
    }

    /// "Who takes it" moved a medication: both people's plans are rebuilt from their text.
    private func reapplyText(for owners: [MedOwner]) async {
        for who in owners {
            let body = store.medsTextOrFallback(for: who)
            let all = RegimenAssembler.lines(of: body)
            let parsed = await parser.parse(lines: all, known: store.knownMedNames(who))
            guard parser.isUpToDate(all) else { continue }
            let result = RegimenAssembler.assemble(text: body, lineParses: parsed, existing: store.existingForAssembler(who))
            store.applyText(who, text: body, assembled: result, confirmed: true)
        }
    }
}

// MARK: - Reorder

private struct MedReorderDelegate: DropDelegate {
    var target: UUID
    @Binding var order: [UUID]
    @Binding var dragging: UUID?
    var current: [UUID]
    var commit: ([UUID]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        var ids = order.isEmpty ? current : order
        for id in current where !ids.contains(id) { ids.append(id) }
        guard let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            order = ids
        }
        Haptics.select()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        if !order.isEmpty { commit(order) }
        return true
    }
}

// MARK: - Timeline

/// Wake to bed as one track: meal bands, and a badge per medication she can drag (5-minute snaps).
/// While dragging: the live time and the first rule it would break. On release the change panel opens.
struct PlanTimeline: View {
    var template: ScheduleTemplate
    var meds: [Medication]
    var times: [UUID: Int]

    @Environment(AppStore.self) private var store
    @State private var drag: (id: UUID, minutes: Int)?

    private let badge: CGFloat = 36
    private let laneHeight: CGFloat = 58
    /// Room each badge and its name need before the next one drops a lane.
    private let slot: CGFloat = 60

    private var wake: Int { template.wake.minutesFromMidnight }
    private var span: Int {
        let bed = template.bed.minutesFromMidnight
        return max(60, bed > wake ? bed - wake : bed + 1440 - wake)
    }
    /// Minutes since wake (doses after midnight count as late evening).
    private func offset(_ m: Int) -> Int {
        let d = m - wake
        return d < -120 ? d + 1440 : d
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let placed = lanes(width: width)
            ZStack(alignment: .topLeading) {
                track(width: width)
                ForEach(placed, id: \.med.id) { item in
                    dot(item.med, lane: item.lane, width: width)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    private var height: CGFloat {
        let count = max(1, (lanes(width: 300).map(\.lane).max() ?? 0) + 1)
        return 34 + CGFloat(count) * laneHeight + 26
    }

    private func x(_ minutes: Int, width: CGFloat) -> CGFloat {
        let usable = width - slot
        return slot / 2 + usable * CGFloat(min(max(offset(minutes), 0), span)) / CGFloat(span)
    }

    /// Badges that would overlap go on the next lane down.
    private func lanes(width: CGFloat) -> [(med: Medication, lane: Int)] {
        let sorted = meds.compactMap { m in times[m.id].map { (m, $0) } }.sorted { offset($0.1) < offset($1.1) }
        var lastX: [CGFloat] = []
        var out: [(Medication, Int)] = []
        for (med, t) in sorted {
            let px = x(t, width: width)
            var lane = 0
            while lane < lastX.count, px - lastX[lane] < slot { lane += 1 }
            if lane == lastX.count { lastX.append(px) } else { lastX[lane] = px }
            out.append((med, lane))
        }
        return out.map { (med: $0.0, lane: $0.1) }
    }

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Theme.ringTrack)
                .frame(width: width, height: 10)
                .offset(y: 14)
            ForEach(template.meals) { meal in
                let start = x(meal.time.minutesFromMidnight, width: width)
                let end = x(meal.time.minutesFromMidnight + meal.durationMinutes, width: width)
                Capsule()
                    .fill(Theme.sage)
                    .frame(width: max(10, end - start), height: 10)
                    .offset(x: start, y: 14)
                Text(meal.name)
                    .font(.bloom(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.sageDeep)
                    .fixedSize()
                    .offset(x: start, y: 0)
                    .accessibilityHidden(true)
            }
            HStack {
                Label(ScheduleEngine.clock(wake), systemImage: "sunrise.fill")
                Spacer()
                Label(ScheduleEngine.clock(template.bed.minutesFromMidnight), systemImage: "moon.fill")
            }
            .labelStyle(.titleAndIcon)
            .font(.bloom(.caption2, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: width)
            .offset(y: height - 18)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func dot(_ med: Medication, lane: Int, width: CGFloat) -> some View {
        let base = times[med.id] ?? wake
        let current = drag?.id == med.id ? drag!.minutes : base
        let isDragging = drag?.id == med.id
        let px = x(current, width: width)
        let y = 34 + CGFloat(lane) * laneHeight
        VStack(spacing: 2) {
            MedBadge(medication: med, size: badge, fill: isDragging ? Theme.blushSoft : Theme.surface)
                .overlay(Circle().stroke(isDragging ? Theme.roseButton : Theme.ringTrack, lineWidth: isDragging ? 2.5 : 1.5))
                .shadow(color: .black.opacity(isDragging ? 0.2 : 0.08), radius: isDragging ? 10 : 4, y: 3)
                .scaleEffect(isDragging ? 1.15 : 1)
            Text(Self.label(med.shortName))
                .font(.bloom(.caption2, weight: .semibold))
                .foregroundStyle(isDragging ? Theme.blushDeep : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: slot - 4)
        }
        .frame(width: slot, height: 54)
        .contentShape(.rect)
        .overlay(alignment: .top) {
            if isDragging { bubble(med, minutes: current, width: width, px: px) }
        }
        .position(x: px, y: y + 27)
        .zIndex(isDragging ? 10 : 0)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if drag == nil { Haptics.select() }
                    let delta = Double(value.translation.width) / Double(max(1, width - slot)) * Double(span)
                    var m = base + Int(delta.rounded())
                    m = Int((Double(m) / 5).rounded()) * 5
                    let low = wake
                    let high = wake + span
                    let normalized = offset(m) + wake
                    m = min(max(normalized, low), high)
                    if m != drag?.minutes { if drag != nil, m % 60 == 0 { Haptics.select() } }
                    drag = (med.id, m)
                }
                .onEnded { _ in
                    guard let d = drag else { return }
                    drag = nil
                    commit(med.id, minutes: d.minutes % 1440)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("\(med.shortName), \(ScheduleEngine.clock(base))")
        .accessibilityHint("Swipe up or down to move by 15 minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(med.id, minutes: (base + 15) % 1440)
            case .decrement: commit(med.id, minutes: (base - 15 + 1440) % 1440)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("timeline-\(med.shortName)")
    }

    /// Short enough for the badge, keeping what tells two doses apart: "Progesterone PM" → "Proge PM".
    static func label(_ name: String) -> String {
        guard name.count > 9 else { return name }
        let words = name.split(separator: " ")
        if words.count > 1, let last = words.last, last.count <= 3 {
            return "\(words[0].prefix(5)) \(last)"
        }
        return name
    }

    private func bubble(_ med: Medication, minutes: Int, width: CGFloat, px: CGFloat) -> some View {
        let broken = brokenRule(med.id, minutes: minutes)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(med.shortName) · \(ScheduleEngine.clock(minutes))")
                .font(.bloom(.caption, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            if let broken {
                Text(broken)
                    .font(.bloom(.caption2, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(broken == nil ? Theme.text : Theme.coralButton, in: .rect(cornerRadius: 12, style: .continuous))
        .frame(width: 210)
        .fixedSize(horizontal: false, vertical: true)
        // Keep it on screen near the edges.
        .offset(x: min(max(px, 105), max(105, width - 105)) - px, y: broken == nil ? -38 : -56)
        .allowsHitTesting(false)
    }

    private func brokenRule(_ id: UUID, minutes: Int) -> String? {
        var t = template
        guard let i = t.doses.firstIndex(where: { $0.medicationID == id }) else { return nil }
        t.doses[i].time = DoseTime(minutes: minutes % 1440)
        return store.violations(in: t).first { $0.rule.involves(id) }.map(ScheduleEngine.shortReason)
    }

    private func commit(_ id: UUID, minutes: Int) {
        var edited = template
        guard let i = edited.doses.firstIndex(where: { $0.medicationID == id }),
              edited.doses[i].time.minutesFromMidnight != minutes else { return }
        edited.doses[i].time = DoseTime(minutes: minutes)
        Haptics.tap()
        store.proposeRoutineChange(original: template, edited: edited, movedDose: id)
    }
}

// MARK: - Medication card

struct MedPlanCard: View {
    var medication: Medication
    var owner: MedOwner
    var template: ScheduleTemplate
    var time: Int?
    var pinned: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var parser: LineParser
    var onOpen: () -> Void
    var onMove: (Bool) -> Void

    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var input = ""
    @State private var reading = false
    @State private var message: String?
    @FocusState private var inputFocused: Bool

    private var names: [UUID: String] {
        Dictionary(store.currentMedications(for: owner).map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
    }
    private var allRules: [ScheduleRule] { store.shownRules(owner) }
    private var myRules: [ScheduleRule] { allRules.filter { $0.subjectID == medication.id } }
    private var savedIDs: Set<UUID> { Set(store.rules(for: owner).map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            let rules = myRules
            if !rules.isEmpty {
                VStack(spacing: 8) {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule, title: RuleValues.title(rule, names: names), isNew: !savedIDs.contains(rule.id),
                                meals: template.meals.sorted { $0.time < $1.time }.map(\.name)) { updated in
                            replace(rule, with: updated)
                        } onDelete: {
                            replace(rule, with: nil)
                        }
                    }
                }
            } else {
                Text("No rules. Bloom places it anywhere between waking up and bed.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(store.violations(in: template).filter { $0.rule.involves(medication.id) && $0.rule.subjectID == medication.id }) { v in
                RuleProblemCard(template: template, violation: v)
            }
            if let change = store.scheduleChange, change.placement == .medication(medication.id) {
                ScheduleChangePanel(change: change)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if adding { addRuleField } else { addRuleButton }
        }
        .padding(16)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Color(light: 0xC9A893, dark: 0x000000).opacity(0.12), radius: 14, y: 5)
        .opacity(medication.paused ? 0.7 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: adding)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: myRules.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-card-\(medication.shortName)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    MedBadge(medication: medication, size: 44, fill: medication.paused ? Theme.surfaceMuted : Theme.blushSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(medication.shortName)
                            .font(.bloom(.headline, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(medication.paused ? "Paused" : (medication.dose.isEmpty ? "No dose written" : medication.dose))
                            .font(.bloom(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Name, photo, who takes it and pause")
            if let time, !medication.paused {
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .accessibilityLabel("Set time")
                    }
                    Text(ScheduleEngine.clock(time))
                        .monospacedDigit()
                }
                .font(.bloom(.subheadline, weight: .bold))
                .foregroundStyle(Theme.blushDeep)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.blushSoft, in: .capsule)
                .contentTransition(.numericText())
            }
            Menu {
                Button { onMove(true) } label: { Label("Move up", systemImage: "arrow.up") }
                    .disabled(!canMoveUp)
                Button { onMove(false) } label: { Label("Move down", systemImage: "arrow.down") }
                    .disabled(!canMoveDown)
                Button(action: onOpen) { Label("Details", systemImage: "info.circle") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More for \(medication.shortName)")
        }
    }

    private var addRuleButton: some View {
        Button {
            Haptics.tap()
            message = nil
            input = ""
            adding = true
            inputFocused = true
        } label: {
            Label("Add a rule", systemImage: "plus")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add-rule-\(medication.shortName)")
    }

    @ViewBuilder
    private var addRuleField: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.aiLookupConsent != true {
                AIConsentNote()
            }
            HStack(spacing: 8) {
                TextField("e.g. at least 5 hours after Iron", text: $input)
                    .font(.bloom(.body))
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit(read)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Theme.surfaceMuted, in: .rect(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("add-rule-input")
                if reading {
                    ShimmerPill()
                } else {
                    Button("Add", action: read)
                        .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.roseButton))
                        .fixedSize()
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || store.aiLookupConsent != true)
                        .accessibilityIdentifier("add-rule-read")
                }
            }
            Text("Type the new rule for \(medication.shortName), e.g. ‘at least 5 hours after Iron’ or ‘no food for 30 min after’.")
                .font(.bloom(.caption))
                .foregroundStyle(Theme.textSecondary)
            if let message {
                Label(message, systemImage: "questionmark.circle.fill")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.peachDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel") {
                adding = false
                inputFocused = false
            }
            .font(.bloom(.subheadline, weight: .semibold))
            .tint(Theme.textSecondary)
        }
    }

    // MARK: Logic

    private func replace(_ rule: ScheduleRule, with updated: ScheduleRule?) {
        var list = allRules
        if let updated, let i = list.firstIndex(where: { $0.id == rule.id }) {
            list[i] = updated
        } else {
            list.removeAll { $0.id == rule.id }
        }
        Haptics.select()
        store.proposeRuleChange(owner: owner, template: template, rules: list, medicationID: medication.id, title: medication.shortName)
    }

    /// The AI only sorts her words into a rule; it never adds one she didn't write.
    private func read() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, store.aiLookupConsent == true, !reading else { return }
        message = nil
        reading = true
        let line = PlanRuleInput.line(raw, medName: medication.shortName, otherNames: [medication.name])
        let known = store.knownMedNames(owner)
        Task {
            let parsed = await parser.parse(lines: [line], known: known)
            reading = false
            guard let parse = parsed[0] else {
                message = parser.failed[LineParseService.normalize(line)] ?? "Bloom couldn't read that. Try again."
                return
            }
            let result = RegimenAssembler.assemble(text: line, lineParses: [0: parse], existing: store.existingForAssembler(owner))
            switch PlanRuleInput.rules(from: result, for: medication.id, existing: allRules) {
            case .success(let added):
                adding = false
                inputFocused = false
                Haptics.success()
                store.proposeRuleChange(owner: owner, template: template, rules: allRules + added,
                                        medicationID: medication.id, title: medication.shortName)
            case .failure(let problem):
                Haptics.warning()
                message = problem.text(medName: medication.shortName)
            }
        }
    }
}

/// Turns the one-line "Add a rule" text into rules for one card.
enum PlanRuleInput {
    enum Problem: Error, Equatable {
        case unknownMedication(String)
        case notAbout
        case duplicate
        case timeOnly
        case nothing

        func text(medName: String) -> String {
            switch self {
            case .unknownMedication(let name): "\(name) isn't in your plan yet. Add it with Add a medication first."
            case .notAbout: "That rule isn't about \(medName)."
            case .duplicate: "\(medName) already has that rule."
            case .timeOnly: "To set a time, drag \(medName) on the timeline above."
            case .nothing: "Bloom couldn't find a rule in that. Try e.g. ‘at least 5 hours after Iron’."
            }
        }
    }

    /// The card's medication goes in front unless she already named it, so the rule is about it.
    static func line(_ raw: String, medName: String, otherNames: [String] = []) -> String {
        let lower = raw.lowercased()
        let named = ([medName] + otherNames).contains { !$0.isEmpty && lower.hasPrefix($0.lowercased()) }
        return named ? raw : "\(medName): \(raw)"
    }

    static func rules(from result: RegimenAssembler.Result, for medID: UUID, existing: [ScheduleRule]) -> Result<[ScheduleRule], Problem> {
        var idMap: [UUID: UUID] = [:]
        for draft in result.drafts {
            guard let existingID = draft.existingID else { return .failure(.unknownMedication(draft.shortName)) }
            idMap[draft.id] = existingID
        }
        var out: [ScheduleRule] = []
        for var rule in result.rules {
            rule.subjectID = idMap[rule.subjectID] ?? rule.subjectID
            if let t = rule.targetMedicationID { rule.targetMedicationID = idMap[t] ?? t }
            guard rule.involves(medID) else { continue }
            guard !RuleSignature.contains(existing + out, rule) else { continue }
            rule.confirmed = false
            out.append(rule)
        }
        if !out.isEmpty { return .success(out) }
        if result.rules.contains(where: { r in
            var m = r
            m.subjectID = idMap[r.subjectID] ?? r.subjectID
            m.targetMedicationID = r.targetMedicationID.map { idMap[$0] ?? $0 }
            return m.involves(medID) && RuleSignature.contains(existing, m)
        }) { return .failure(.duplicate) }
        if !result.rules.isEmpty { return .failure(.notAbout) }
        if result.drafts.contains(where: { $0.fixedTime != nil }) { return .failure(.timeOnly) }
        return .failure(.nothing)
    }
}

// MARK: - Rule row

/// "No food after · 30 min" with − / + right on the row. Swipe left to delete.
struct RuleRow: View {
    var rule: ScheduleRule
    var title: String
    var isNew: Bool
    var meals: [String]
    var onChange: (ScheduleRule) -> Void
    var onDelete: () -> Void

    private let reveal: CGFloat = 76

    /// A native horizontal scroll reveals the delete button, so vertical scrolling that starts on a row
    /// still scrolls the page (a drag gesture here would swallow it).
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                content
                    .containerRelativeFrame(.horizontal)
                Button(role: .destructive) {
                    Haptics.tap()
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: reveal - 8)
                        .frame(maxHeight: .infinity)
                        .background(Theme.coralButton, in: .rect(cornerRadius: 18, style: .continuous))
                }
                .accessibilityHidden(true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .contextMenu {
            Button(role: .destructive, action: onDelete) { Label("Delete rule", systemImage: "trash") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Delete rule", onDelete)
    }

    private var isRange: Bool {
        if case .range = RuleValues.control(for: rule) { return true }
        return false
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(rule.isNoFood ? Theme.coralDeep : Theme.sageDeep)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if isNew {
                    Text("NEW")
                        .font(.bloom(.caption2, weight: .heavy))
                        .foregroundStyle(Theme.blushDeep)
                }
                Text(title)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
            }
        }
    }

    /// A range has two steppers, so they sit under the sentence instead of squeezing it.
    @ViewBuilder
    private var content: some View {
        Group {
            if isRange {
                VStack(alignment: .leading, spacing: 6) {
                    label
                        .padding(.top, 6)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { rangeControls }
                        VStack(alignment: .leading, spacing: 4) { rangeControls }
                    }
                    .padding(.leading, 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    label
                    Spacer(minLength: 6)
                    control
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(isNew ? Theme.blushSoft : Theme.surfaceMuted, in: .rect(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: title)
    }

    private var icon: String {
        switch rule.target {
        case .food: "fork.knife"
        case .meal: "takeoutbag.and.cup.and.straw.fill"
        case .wake: "sunrise.fill"
        case .bed: "moon.fill"
        case .medication: "arrow.left.and.right"
        }
    }

    @ViewBuilder
    private var control: some View {
        switch RuleValues.control(for: rule) {
        case .minutes(_, let lowest):
            let value = rule.minMinutes ?? 0
            StepperPair(label: title, value: value, lowest: min(lowest, value)) { new in
                var r = rule
                r.minMinutes = new
                onChange(r)
            }
        case .range:
            VStack(alignment: .trailing, spacing: 4) { rangeControls }
        case .meal:
            Menu {
                ForEach(meals, id: \.self) { meal in
                    Button {
                        var r = rule
                        r.targetMeal = meal
                        onChange(r)
                    } label: {
                        if meal.caseInsensitiveCompare(rule.targetMeal ?? "") == .orderedSame {
                            Label(meal, systemImage: "checkmark")
                        } else {
                            Text(meal)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(rule.targetMeal ?? "Meal")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.bloom(.subheadline, weight: .bold))
                .foregroundStyle(Theme.blushDeep)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.surface, in: .capsule)
            }
            .accessibilityLabel("Meal, \(rule.targetMeal ?? "none")")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rangeControls: some View {
        let from = rule.minMinutes ?? 0
        let to = rule.maxMinutes ?? from
        rangeRow("From", value: from, lowest: 0, highest: to) { new in
            var r = rule
            r.minMinutes = new
            onChange(r)
        }
        rangeRow("To", value: to, lowest: from, highest: 23 * 60) { new in
            var r = rule
            r.maxMinutes = new
            onChange(r)
        }
    }

    private func rangeRow(_ label: String, value: Int, lowest: Int, highest: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.bloom(.caption, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 34, alignment: .leading)
            StepperPair(label: "\(label), \(title)", value: value, lowest: lowest, highest: highest, compact: true, set: set)
        }
    }
}

/// − value + with 44-point buttons.
private struct StepperPair: View {
    var label: String
    var value: Int
    var lowest: Int
    var highest: Int = 23 * 60
    var compact = false
    var set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("minus", enabled: value > lowest) { set(max(lowest, RuleValues.stepped(value, up: false, lowest: lowest))) }
            if compact {
                Text(ScheduleEngine.duration(value))
                    .font(.bloom(.caption, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                    .contentTransition(.numericText())
            }
            button("plus", enabled: value < highest) { set(min(highest, RuleValues.stepped(value, up: true, lowest: lowest))) }
        }
        .background(Theme.surface, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(ScheduleEngine.duration(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < highest { set(min(highest, RuleValues.stepped(value, up: true, lowest: lowest))) }
            case .decrement: if value > lowest { set(max(lowest, RuleValues.stepped(value, up: false, lowest: lowest))) }
            @unknown default: break
            }
        }
    }

    private func button(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Theme.blushDeep : Theme.textSecondary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Consent

/// The same promise as the text screen, shortened for a one-line prompt.
struct AIConsentNote: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Before Bloom reads this", systemImage: "hand.raised.fill")
                .font(.bloom(.subheadline, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Bloom sends only this line (and the medication's name) to Rork's AI service, which passes it through Vercel AI Gateway to DeepSeek (Anthropic Claude if that's slow). It only sorts it into a rule; times are worked out on this iPhone. Nothing changes until you confirm.")
                .font(.bloom(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow") {
                Haptics.tap()
                store.setAILookupConsent(true)
            }
            .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.roseButton))
            .accessibilityIdentifier("ai-consent-allow")
        }
        .padding(14)
        .background(Theme.blushSoft, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Add a medication

struct AddMedicationPromptSheet: View {
    var owner: MedOwner
    var parser: LineParser
    var onDone: (UUID?) -> Void

    @Environment(AppStore.self) private var store
    @State private var input = ""
    @State private var reading = false
    @State private var result: RegimenAssembler.Result?
    @State private var message: String?
    @State private var confirmed = false
    @FocusState private var focused: Bool

    private var newDrafts: [RegimenMedDraft] { result?.drafts.filter { $0.existingID == nil } ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.aiLookupConsent != true { AIConsentNote() }
                    HStack(spacing: 8) {
                        TextField("e.g. Calcium 500 mg with dinner", text: $input)
                            .font(.bloom(.body))
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(read)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(Theme.surface, in: .rect(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("add-med-input")
                        if reading {
                            ShimmerPill()
                        } else {
                            Button("Read", action: read)
                                .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.roseButton))
                                .fixedSize()
                                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || store.aiLookupConsent != true)
                        }
                    }
                    Text("Type the medication with its dose and any rule, the way your doctor or pharmacist said it. Bloom never adds a dose.")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                    if let message {
                        Label(message, systemImage: "questionmark.circle.fill")
                            .font(.bloom(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.peachDeep)
                    }
                    if let result, !newDrafts.isEmpty { preview(result) }
                }
                .padding(20)
            }
            .background(BloomBackground())
            .navigationTitle("Add a medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func preview(_ result: RegimenAssembler.Result) -> some View {
        let names = Dictionary(result.drafts.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
            .merging(store.currentMedications(for: owner).map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(newDrafts) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("💊").font(.system(size: 26))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.shortName)
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text(draft.dose.isEmpty ? "No dose written" : draft.dose)
                                .font(.bloom(.footnote))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let fixed = draft.fixedTime {
                        Label("At \(ScheduleEngine.clock(fixed.minutesFromMidnight))", systemImage: "pin.fill")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    ForEach(result.rules.filter { $0.subjectID == draft.id || $0.targetMedicationID == draft.id }) { rule in
                        Label(RuleValues.title(rule, names: names), systemImage: rule.isNoFood ? "fork.knife" : "arrow.left.and.right")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(Theme.surfaceMuted, in: .rect(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(16)
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            }
            Toggle(isOn: $confirmed) {
                Text("Matches my doctor or pharmacist")
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.sageButton)
            .frame(minHeight: 44)
            .accessibilityIdentifier("add-med-confirm")
            Button {
                let id = store.addMedications(owner, drafts: result.drafts, rules: result.rules)
                Haptics.success()
                onDone(id)
            } label: {
                Text("Add to my plan")
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .disabled(!confirmed)
            .opacity(confirmed ? 1 : 0.5)
            .accessibilityIdentifier("add-med-apply")
        }
    }

    private func read() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, store.aiLookupConsent == true, !reading else { return }
        reading = true
        message = nil
        result = nil
        confirmed = false
        let known = store.knownMedNames(owner)
        Task {
            let parsed = await parser.parse(lines: [raw], known: known)
            reading = false
            guard let parse = parsed[0] else {
                message = parser.failed[LineParseService.normalize(raw)] ?? "Bloom couldn't read that. Try again."
                return
            }
            let assembled = RegimenAssembler.assemble(text: raw, lineParses: [0: parse], existing: store.existingForAssembler(owner))
            if assembled.drafts.allSatisfy({ $0.existingID != nil }) {
                message = assembled.drafts.isEmpty
                    ? "Bloom couldn't find a medication in that."
                    : "\(assembled.drafts.map(\.shortName).joined(separator: ", ")) is already in your plan. Add rules on its card."
                Haptics.warning()
                return
            }
            focused = false
            result = assembled
            Haptics.success()
        }
    }
}
