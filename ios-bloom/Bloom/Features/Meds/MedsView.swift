import SwiftUI

enum MedsRoute: Hashable {
    case manage
    case schedule(MedOwner)
}

/// Meds tab: day picker, Right now card and the day as one time-ordered list.
/// Wide (Duo inner display, landscape): Right now + day picker left, the list right, editor as a side panel.
struct MedsView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedDay: Date = PregnancyMath.calendar.startOfDay(for: .now)
    @State private var showEditor = false
    @State private var editingMedication: Medication?
    @State private var editorToken = UUID()
    /// A row is being dragged: the list stops scrolling.
    @State private var rowDragging = false
    /// Whose meds are on screen when shared (nil = the default for this viewer).
    @State private var personChoice: MedOwner?
    @State private var showQuiz = false
    @State private var showBox = false
    @State private var path = NavigationPath()

    private var cal: Calendar { PregnancyMath.calendar }
    private var today: Date { cal.startOfDay(for: store.now) }
    private var isToday: Bool { cal.isDate(selectedDay, inSameDayAs: today) }
    private var isFuture: Bool { selectedDay > today }

    /// Shared: one person's meds at a time. Single phone: everything.
    private var person: MedOwner? { store.isShared ? (personChoice ?? store.defaultMedsPerson) : nil }

    /// Whose routine Add and Schedule work on.
    private var owner: MedOwner { person ?? store.viewerRole }

    private var visibleMedications: [Medication] {
        guard let person else { return store.medications }
        return store.medications.filter { $0.owner == person }
    }

    /// The name used in "you" wording when the meds on screen aren't the viewer's.
    private var personName: String? {
        guard let person, person != store.viewerRole else { return nil }
        return store.name(for: person)
    }

    private func visibleInstances(on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: visibleMedications, logs: store.doseLogs)
    }

    private var visibleCarryOver: [DoseInstance] {
        MedsEngine.carryOver(into: today, medications: visibleMedications, logs: store.doseLogs)
    }

    @ViewBuilder
    private var personSwitcher: some View {
        if store.isShared {
            MedsPersonSwitcher(selection: Binding(
                get: { person ?? store.viewerRole },
                set: { personChoice = $0 }
            ))
            .padding(.horizontal, 20)
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            Group {
                if store.medications.isEmpty {
                    emptyState
                } else {
                    content
                        .environment(\.medsPerson, personName)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: MedsRoute.manage) {
                        Label("Medications", systemImage: "list.bullet")
                    }
                    .tint(Theme.blushDeep)
                    .disabled(store.medications.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: MedsRoute.schedule(owner)) {
                        Label("Routines", systemImage: "calendar.day.timeline.left")
                    }
                    .tint(Theme.blushDeep)
                    .accessibilityIdentifier("meds-schedule")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startAdd()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .tint(Theme.blushDeep)
                    .accessibilityIdentifier("meds-add")
                }
            }
            .navigationDestination(for: MedsRoute.self) { route in
                switch route {
                case .manage:
                    ManageMedsView(onEdit: { openEditor($0) }, onAdd: { startAdd() })
                case .schedule(let who):
                    TemplatesView(owner: who)
                }
            }
        }
        .sheet(isPresented: $showQuiz) {
            RoutineQuizView(owner: owner, template: nil, days: nil) { saved in
                showQuiz = false
                // A new routine goes straight on to the medication list.
                if saved != nil, store.scheduledMedications(for: owner).isEmpty {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        showBox = true
                    }
                }
            }
        }
        .sheet(isPresented: $showBox) {
            MedsBoxView(owner: owner, onClose: { showBox = false }, onOpenSchedule: {
                showBox = false
                path.append(MedsRoute.schedule(owner))
            })
        }
        .inspector(isPresented: $showEditor) {
            Group {
                if let editingMedication {
                    AddMedicationView(medication: editingMedication) { showEditor = false }
                } else {
                    QuickAddMedicationView { showEditor = false }
                }
            }
            .id(editorToken)
            .inspectorColumnWidth(min: 340, ideal: 380, max: 440)
            .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            // A finished part of the day shows a short inline line first, then the undo toast.
            if let celebration = store.celebration {
                CompletionBanner(headline: celebrationHeadline(celebration),
                                 subtitle: celebrationSubtitle(celebration)) {
                    if store.celebration?.id == celebration.id { store.celebration = nil }
                }
                .id(celebration.id)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast = store.undoToast {
                UndoToastView(toast: toast) {
                    store.undo(medicationID: toast.medicationID, scheduledAt: toast.scheduledAt)
                } onExpire: {
                    if store.undoToast?.id == toast.id { store.undoToast = nil }
                }
                .id(toast.id)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.undoToast?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.celebration?.id)
        .onChange(of: today) { oldValue, newValue in
            // Follow the calendar across midnight when the user was looking at "today".
            if cal.isDate(selectedDay, inSameDayAs: oldValue) { selectedDay = newValue }
        }
    }

    private var title: String {
        if isToday { return "Meds today" }
        return selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let instances = visibleInstances(on: selectedDay)
        AdaptiveColumns {
            ScrollView {
                VStack(spacing: 20) {
                    personSwitcher
                    dayPicker
                    overview(instances)
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 8)
                .padding(.bottom, 80)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(rowDragging)
        } secondary: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        listHeader(large: true)
                        dayList(instances)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .padding(.bottom, 80)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollDisabled(rowDragging)
                .modifier(RevealRowPanel(proxy: proxy))
            }
        } compact: {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    personSwitcher
                    dayPicker
                    VStack(alignment: .leading, spacing: 14) {
                        overview(instances)
                        listHeader(large: false)
                            .padding(.top, 8)
                        dayList(instances)
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 8)
                .padding(.bottom, 80)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(rowDragging)
            .modifier(RevealRowPanel(proxy: proxy))
            }
            .background(BloomBackground())
        }
        .onChange(of: store.scheduleChange?.id) { _, id in
            // A panel only appears once a drag or edit has finished.
            if id != nil { rowDragging = false }
        }
    }

    private func listHeader(large: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isToday ? (personName.map { "\($0)'s day" } ?? "Your day") : selectedDay.formatted(.dateTime.weekday(.wide)))
                .font(.bloom(large ? .title2 : .title3, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            routineMenu
        }
    }

    /// "Weekdays routine": on today, switch today to another routine; otherwise open Routines.
    @ViewBuilder
    private var routineMenu: some View {
        if let active = store.activeTemplate(for: owner, on: selectedDay) {
            let all = store.templates(for: owner)
            Menu {
                if isToday, all.count > 1 {
                    Section("Today follows") {
                        ForEach(all) { t in
                            Button {
                                store.switchRoutine(owner, on: selectedDay, to: t)
                            } label: {
                                if t.id == active.id {
                                    Label("\(t.displayName) routine", systemImage: "checkmark")
                                } else {
                                    Text("\(t.displayName) routine")
                                }
                            }
                            .accessibilityIdentifier("switch-routine-\(t.displayName)")
                        }
                    }
                }
                Button {
                    path.append(MedsRoute.schedule(owner))
                } label: {
                    Label("Edit routines", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(active.displayName) routine")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.blushDeep)
            }
            .accessibilityIdentifier("meds-open-routine")
        }
    }

    @ViewBuilder
    private func dayList(_ instances: [DoseInstance]) -> some View {
        if !store.hasRoutine(owner), !visibleMedications.isEmpty {
            routinePrompt
        }
        MedsTodayList(
            instances: instances,
            meals: store.meals(for: owner, on: selectedDay),
            day: selectedDay,
            owner: owner,
            canLog: !isFuture,
            now: isToday ? store.now : nil,
            actions: doseActions,
            onDragging: { rowDragging = $0 }
        )
    }

    /// Medications from before routines existed: offer to plan them around the day.
    private var routinePrompt: some View {
        Button {
            Haptics.tap()
            showQuiz = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sun.horizon")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.blushDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan around your day")
                        .font(.bloom(.headline, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Tell Bloom when you wake, eat and sleep, then list your medications and rules.")
                        .font(.bloom(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("meds-plan-routine")
    }

    private var dayPicker: some View {
        DayPicker(selection: $selectedDay, today: today) { day in
            let instances = visibleInstances(on: day)
            return (instances.filter { !$0.isPending }.count, instances.count)
        }
    }

    @ViewBuilder
    private func overview(_ instances: [DoseInstance]) -> some View {
        if isToday {
            VStack(spacing: 12) {
                RightNowCard(
                    instances: instances,
                    carryOver: visibleCarryOver,
                    onTaken: { store.markTaken($0, at: $1, placement: .top) },
                    onSkip: { store.skip($0) }
                )
                if let change = store.scheduleChange, change.placement == .top,
                   cal.isDate(change.date, inSameDayAs: selectedDay), person == nil || change.owner == person {
                    ScheduleChangePanel(change: change)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.scheduleChange?.id)
        } else {
            DaySummaryCard(day: selectedDay, instances: instances, isFuture: isFuture)
        }
    }

    private var doseActions: DoseActions {
        DoseActions(
            taken: { store.markTaken($0, at: $1, placement: .row($0.medication.id)) },
            skip: { store.skip($0) },
            undo: { store.undo($0) },
            edit: { med in openEditor(store.medications.first { $0.id == med.id } ?? med) }
        )
    }

    private var emptyState: some View {
        ZStack {
            BloomBackground()
            CenteredScroll {
                VStack(spacing: 16) {
                    Image(systemName: "sun.horizon")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Theme.blushDeep)
                    Text(store.hasRoutine(owner) ? "List your medications" : "Set up your routine")
                        .font(.bloom(.title, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text(store.hasRoutine(owner)
                         ? "Write them in one go with any rules about timing, food or each other. Bloom works out the times."
                         : "A few questions about when you wake, eat and sleep. Then list your medications and Bloom places every dose around your day.")
                        .font(.bloom(.body))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        startAdd()
                    } label: {
                        Text(store.hasRoutine(owner) ? "List medications" : "Set up your routine")
                    }
                    .buttonStyle(BloomPrimaryButtonStyle())
                    .frame(maxWidth: 360)
                    .padding(.top, 6)
                    .accessibilityIdentifier("meds-setup")
                }
                .padding(32)
            }
        }
    }

    /// No routine yet: the quiz first (it hands over to the medication box). Otherwise the box.
    private func startAdd() {
        Haptics.tap()
        if store.hasRoutine(owner) { showBox = true } else { showQuiz = true }
    }

    // MARK: Celebration wording

    private func celebrationHeadline(_ celebration: SlotCelebration) -> String {
        let taker = celebration.taker
        if store.isShared, taker != store.viewerRole {
            return "\(store.name(for: taker))'s \(celebration.slot.title.lowercased()) doses are done"
        }
        return "\(celebration.slot.title) doses done"
    }

    private func celebrationSubtitle(_ celebration: SlotCelebration) -> String {
        let percent = Int((celebration.progress * 100).rounded())
        if store.isShared, celebration.taker != store.viewerRole {
            return "\(percent)% of \(store.name(for: celebration.taker))'s doses logged today"
        }
        let streak = celebration.streak > 0 ? " · \(celebration.streak)-day streak" : ""
        return "\(percent)% of today's doses logged" + streak
    }

    private func openEditor(_ medication: Medication?) {
        Haptics.tap()
        editingMedication = medication
        editorToken = UUID()
        showEditor = true
    }
}

// MARK: - Completion line

/// A quiet inline confirmation when a part of the day is finished:
/// an animated checkmark, a light haptic and one short line.
private struct CompletionBanner: View {
    var headline: String
    var subtitle: String
    var onExpire: () -> Void
    @State private var checked = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(Theme.sageDeep)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: checked)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            checked = true
            Haptics.celebrate()
            try? await Task.sleep(for: .seconds(3.5))
            onExpire()
        }
    }
}

// MARK: - Undo toast

private struct UndoToastView: View {
    var toast: UndoToast
    var onUndo: () -> Void
    var onExpire: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.isSkip ? "minus.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isSkip ? Color(uiColor: .secondaryLabel) : Theme.sageDeep)
            Text(toast.message)
                .font(.bloom(.subheadline, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .frame(maxWidth: 520)
        .task {
            try? await Task.sleep(for: .seconds(8))
            onExpire()
        }
    }
}

/// Scrolls a schedule-change panel that opens under a list row into view, so it is
/// never left below the screen edge (on the open iPhone Duo the list fills its pane).
private struct RevealRowPanel: ViewModifier {
    var proxy: ScrollViewProxy
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.onChange(of: store.scheduleChange?.id) { _, id in
            guard id != nil, let change = store.scheduleChange,
                  case .row = change.placement else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.smooth(duration: 0.4)) {
                    proxy.scrollTo(ScheduleChangePanel.scrollID, anchor: .bottom)
                }
            }
        }
    }
}
