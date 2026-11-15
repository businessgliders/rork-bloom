import SwiftUI

/// One person's routines on one screen. Tap a routine to open it in place: name, days, wake, meals,
/// bedtime and medication times. Changing a time re-plans the routine and asks inline:
/// "Just today" / "Going forward" / "Undo". No two routines share a day.
struct TemplatesView: View {
    var owner: MedOwner

    @Environment(AppStore.self) private var store
    @State private var expanded: UUID?
    @State private var showQuiz = false
    @State private var showBox = false
    @State private var pendingDelete: ScheduleTemplate?
    @State private var pendingMove: DayMove?
    @State private var names: [UUID: String] = [:]

    private struct DayMove: Identifiable {
        var day: Int
        var template: ScheduleTemplate
        var from: ScheduleTemplate
        var id: String { "\(day)-\(template.id)" }
    }

    private var templates: [ScheduleTemplate] { store.templates(for: owner) }
    private var freeDays: Set<Int> { Set(0...6).subtracting(store.takenDays(for: owner, excluding: nil)) }
    private var meds: [Medication] { store.scheduledMedications(for: owner) }
    private var rules: [ScheduleRule] { store.rules(for: owner) }
    private var todayID: UUID? { store.activeTemplate(for: owner, on: store.now)?.id }

    var body: some View {
        List {
            if templates.isEmpty {
                Section {
                    Text("No routine yet. Tell Bloom when you wake, eat and sleep, and it places every dose around your day.")
                        .font(.bloom(.body))
                        .foregroundStyle(Theme.textSecondary)
                    Button { Haptics.tap(); showQuiz = true } label: {
                        Label("Set up your routine", systemImage: "sun.horizon")
                    }
                    .tint(Theme.blushDeep)
                    .accessibilityIdentifier("templates-new")
                }
            }

            ForEach(templates) { t in
                routineSection(t)
            }

            if let source = templates.first(where: { $0.id == expanded }) ?? templates.first(where: { $0.id == todayID }) ?? templates.first {
                Section {
                    Button { copy(source) } label: {
                        Label("Copy \(source.displayName)", systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier("templates-duplicate")
                } footer: {
                    Text(freeDays.isEmpty
                         ? "The copy starts with no days. Pick its days, and they move over from the other routine."
                         : "The copy takes \(ScheduleTemplate.daysLabel(freeDays)), which \(freeDays.count == 1 ? "has" : "have") no routine yet.")
                        .font(.bloom(.caption))
                }
                .tint(Theme.blushDeep)
                .font(.bloom(.body, weight: .semibold))
            }

            Section {
                if meds.isEmpty {
                    Text("No medications in the routine yet.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(meds) { med in
                        Text(med.shortName)
                            .font(.bloom(.body, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
                ForEach(rules) { rule in
                    Text(store.describe(rule))
                        .font(.bloom(.subheadline))
                        .foregroundStyle(rule.isNoFood ? Theme.coralDeep : Theme.textSecondary)
                }
                Button { Haptics.tap(); showBox = true } label: {
                    Label("Edit medications & rules", systemImage: "text.badge.checkmark")
                        .font(.bloom(.body, weight: .semibold))
                }
                .tint(Theme.blushDeep)
                .disabled(templates.isEmpty)
                .accessibilityIdentifier("templates-edit-meds")
            } header: {
                Text("Medications & rules")
            }
        }
        .duoListClearance()
        .navigationTitle(store.isShared && owner != store.viewerRole ? "\(store.name(for: owner))'s routines" : "Routines")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: store.scheduleChange?.id)
        .onAppear {
            if expanded == nil { expanded = templates.count == 1 ? templates.first?.id : nil }
        }
        .onDisappear {
            if case .routine = store.scheduleChange?.placement { store.scheduleChange = nil }
        }
        .sheet(isPresented: $showQuiz) {
            RoutineQuizView(owner: owner, template: nil, days: nil) { saved in
                showQuiz = false
                if let saved { expanded = saved.id }
                if saved != nil, store.scheduledMedications(for: owner).isEmpty {
                    Task { try? await Task.sleep(for: .milliseconds(450)); showBox = true }
                }
            }
        }
        .sheet(isPresented: $showBox) {
            MedsBoxView(owner: owner, onClose: { showBox = false })
        }
        .confirmationDialog("Delete the \(pendingDelete?.displayName ?? "") routine?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                if let pendingDelete { store.deleteTemplate(pendingDelete) }
                Haptics.warning()
                pendingDelete = nil
            }
        } message: {
            Text("Medications on those days won't have planned times until another routine covers them.")
        }
        .confirmationDialog(moveTitle, isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
                            titleVisibility: .visible) {
            Button("Move \(dayName(pendingMove?.day ?? 0))") {
                if let pendingMove { store.moveDay(pendingMove.day, to: pendingMove.template) }
                Haptics.success()
                pendingMove = nil
            }
            .accessibilityIdentifier("move-day-confirm")
        } message: {
            Text("A day follows one routine at a time.")
        }
    }

    private var moveTitle: String {
        guard let m = pendingMove else { return "" }
        return "\(dayName(m.day)) follows your \(m.from.displayName) routine. Move it to \(m.template.displayName)?"
    }

    private func dayName(_ day: Int) -> String { PregnancyMath.calendar.weekdaySymbols[day] }

    // MARK: A routine

    /// The routine as it would be with the pending change, so pickers show what she just chose.
    private func shown(_ t: ScheduleTemplate) -> (template: ScheduleTemplate, change: ScheduleChange?) {
        guard let change = store.scheduleChange, change.placement == .routine(t.id), var draft = change.draft else { return (t, nil) }
        for (id, m) in change.times {
            if let i = draft.doses.firstIndex(where: { $0.medicationID == id }) { draft.doses[i].time = DoseTime(minutes: m) }
        }
        return (draft, change)
    }

    @ViewBuilder
    private func routineSection(_ t: ScheduleTemplate) -> some View {
        let isOpen = expanded == t.id
        let (draft, change) = shown(t)
        let broken = change == nil ? store.violations(in: t) : []
        Section {
            Button {
                Haptics.select()
                if expanded == t.id { expanded = nil } else { expanded = t.id }
            } label: {
                RoutineHeader(template: t, isToday: t.id == todayID, broken: broken.count, isOpen: isOpen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routine-\(t.displayName)")

            if isOpen {
                TextField(t.displayName, text: Binding(
                    get: { names[t.id] ?? (t.displayName == ScheduleTemplate.autoName(t.days) ? "" : t.name) },
                    set: { names[t.id] = $0 }
                ))
                .font(.bloom(.body))
                .submitLabel(.done)
                .onSubmit { rename(t) }
                .accessibilityIdentifier("routine-name")

                DayChips(days: t.days) { day in tapDay(day, in: t) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

                timeRow("Wake up", systemImage: "sunrise", tint: Theme.peachDeep, time: draft.wake, id: "routine-wake") { new in
                    var e = draft
                    e.wake = new
                    store.proposeRoutineChange(original: t, edited: e)
                }
                ForEach(draft.meals) { meal in
                    timeRow(meal.name, systemImage: "fork.knife", tint: Theme.sageDeep, time: meal.time,
                            id: "routine-meal-\(meal.name)") { new in
                        var e = draft
                        if let i = e.meals.firstIndex(where: { $0.id == meal.id }) { e.meals[i].time = new }
                        store.proposeRoutineChange(original: t, edited: e)
                    }
                }
                timeRow("Bedtime", systemImage: "moon", tint: Theme.peachDeep, time: draft.bed, id: "routine-bed") { new in
                    var e = draft
                    e.bed = new
                    store.proposeRoutineChange(original: t, edited: e)
                }
                ForEach(draft.doses.sorted { $0.time < $1.time }) { dose in
                    let name = store.medicationNames[dose.medicationID] ?? "Medication"
                    timeRow(name, systemImage: dose.pinned ? "pin.fill" : "pills", tint: Theme.blushDeep, time: dose.time,
                            id: "routine-dose-\(name)") { new in
                        var e = draft
                        if let i = e.doses.firstIndex(where: { $0.medicationID == dose.medicationID }) { e.doses[i].time = new }
                        store.proposeRoutineChange(original: t, edited: e, movedDose: dose.medicationID)
                    }
                }

                if let change {
                    ScheduleChangePanel(change: change)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                ForEach(broken) { v in
                    RuleProblemCard(template: t, violation: v)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                HStack {
                    Button { copy(t) } label: { Label("Copy", systemImage: "plus.square.on.square") }
                        .buttonStyle(BloomSoftButtonStyle())
                    Spacer()
                    Button(role: .destructive) { pendingDelete = t } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(BloomSoftButtonStyle(tint: Theme.coralDeep))
                }
                .font(.bloom(.subheadline, weight: .semibold))
            }
        }
    }

    private func timeRow(_ title: String, systemImage: String, tint: Color, time: DoseTime, id: String,
                         onChange: @escaping (DoseTime) -> Void) -> some View {
        DatePicker(selection: Binding(
            get: { time.date(on: .now) },
            set: { new in
                let t = DoseTime(date: new)
                if t != time { onChange(t) }
            }
        ), displayedComponents: .hourAndMinute) {
            Label {
                Text(title).font(.bloom(.body))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
        .accessibilityIdentifier(id)
    }

    // MARK: Actions

    private func rename(_ t: ScheduleTemplate) {
        guard let typed = names[t.id] else { return }
        var e = store.templates.first { $0.id == t.id } ?? t
        e.name = typed.trimmingCharacters(in: .whitespaces)
        store.saveTemplate(e, regenerate: false)
        names[t.id] = nil
        Haptics.select()
    }

    private func tapDay(_ day: Int, in t: ScheduleTemplate) {
        Haptics.select()
        if t.days.contains(day) {
            var e = t
            e.days.remove(day)
            store.saveTemplate(e, regenerate: false)
        } else if let other = templates.first(where: { $0.id != t.id && $0.days.contains(day) }) {
            pendingMove = DayMove(day: day, template: t, from: other)
        } else {
            store.moveDay(day, to: t)
        }
    }

    private func copy(_ t: ScheduleTemplate) {
        Haptics.success()
        store.scheduleChange = nil
        let made = store.duplicateTemplate(t)
        expanded = made.id
    }
}

// MARK: - Pieces

private struct RoutineHeader: View {
    var template: ScheduleTemplate
    var isToday: Bool
    var broken: Int
    var isOpen: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(template.displayName)
                        .font(.bloom(.headline, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if isToday {
                        Text("Today")
                            .font(.bloom(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.blushDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.blushSoft, in: .capsule)
                    }
                    if broken > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.coralDeep)
                            .accessibilityLabel("\(broken) rules not met")
                    }
                }
                Text(summary)
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var summary: String {
        let days = template.days.isEmpty ? "No days" : ScheduleTemplate.daysLabel(template.days)
        return "\(days) · \(ScheduleEngine.clock(template.wake.minutesFromMidnight))–\(ScheduleEngine.clock(template.bed.minutesFromMidnight)) · \(template.doses.count) \(template.doses.count == 1 ? "medication" : "medications")"
    }
}

/// S M T W T F S. A day belongs to one routine; picking a day another routine has offers to move it.
struct DayChips: View {
    var days: Set<Int>
    var onTap: (Int) -> Void

    var body: some View {
        let symbols = PregnancyMath.calendar.veryShortWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(ScheduleTemplate.orderedDays, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    onTap(day)
                } label: {
                    Text(symbols[day])
                        .font(.bloom(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .foregroundStyle(on ? .white : Theme.blushDeep)
                        .background(on ? Theme.blush : Theme.blushSoft, in: .circle)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(PregnancyMath.calendar.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("day-chip-\(day)")
            }
        }
    }
}

/// A rule a routine breaks: why, and one-tap fixes that keep every rule.
struct RuleProblemCard: View {
    var template: ScheduleTemplate
    var violation: RuleViolation
    @Environment(AppStore.self) private var store

    var body: some View {
        let fixes = store.templateFixes(template, for: violation)
        VStack(alignment: .leading, spacing: 8) {
            Label(store.templateBlockedReason(template, for: violation), systemImage: "exclamationmark.triangle.fill")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.coralDeep)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(fixes) { fix in
                Button {
                    store.applyTemplateFix(template.id, fix: fix)
                } label: {
                    Label(fix.title, systemImage: icon(for: fix))
                        .font(.bloom(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BloomSoftButtonStyle())
                .accessibilityIdentifier("rule-fix")
            }
            if fixes.isEmpty {
                Text("Change a meal, wake or bedtime above to make room.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.coralSoft, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func icon(for fix: ScheduleFix) -> String {
        switch fix.kind {
        case .move: "arrow.up.arrow.down"
        case .skip: "forward.end"
        case .retime(let tweak): tweak.bed != nil ? "moon" : tweak.wake != nil ? "sunrise" : "fork.knife"
        }
    }
}
