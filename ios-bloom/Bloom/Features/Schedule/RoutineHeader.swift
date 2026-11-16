import SwiftUI

/// Routine chips, one row of day-anchor time cards (wake, meals, bed) and the routine's change panel.
/// Shared by the plan screen and the text setup screen.
struct RoutineHeader: View {
    var owner: MedOwner
    @Binding var selectedRoutine: UUID?
    /// The old wake / meals / bed cards. Meds & routines and the editor show those times in the list instead.
    var showTimeCards = true

    @Environment(AppStore.self) private var store

    @State private var openCard: TimeCard?
    @State private var showQuiz = false
    @State private var renaming: ScheduleTemplate?
    @State private var renameText = ""
    @State private var daysFor: ScheduleTemplate?
    @State private var pendingDelete: ScheduleTemplate?

    private var templates: [ScheduleTemplate] { store.templates(for: owner) }
    private var routine: ScheduleTemplate? {
        templates.first { $0.id == selectedRoutine } ?? store.activeTemplate(for: owner, on: store.now) ?? templates.first
    }
    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }

    var body: some View {
        routineArea
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: openCard)
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
                if showTimeCards { timeCards(t) }
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
                                Circle().fill(on ? Color.white : Theme.rose).frame(width: 6, height: 6)
                                    .accessibilityLabel("Today")
                            }
                            Text(t.displayName)
                            if !store.violations(in: t).isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(on ? .white : Theme.terraDot)
                                    .accessibilityLabel("A rule can't be met")
                            }
                        }
                        .font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Theme.dayText)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(on ? Theme.rose : Theme.dayCard, in: .capsule)
                        .overlay(Capsule().stroke(on ? .clear : Theme.dayDivider, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(.rect)
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.rose)
                        .frame(width: 36, height: 36)
                        .background(Theme.roseTint, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
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
}
