import SwiftUI

enum MedsRoute: Hashable {
    /// Meds & routines: My rules, routines and the day's list.
    case schedule(MedOwner)
    /// The My rules editor, optionally at the line that names a medication.
    case rules(MedOwner, focus: String?)
}

/// Board 1: Meds today. Title + streak, week strip, one status card, one list card.
/// The signed-in person's meds; when they take none, the partner's day (still loggable).
/// Open iPhone Duo (board 5): week, status and the Next card left; "Today" and the list right.
struct MedsView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedDay: Date = PregnancyMath.calendar.startOfDay(for: .now)
    @State private var showQuiz = false
    @State private var showProgress = false
    @State private var sheetMed: Medication?
    @State private var path = NavigationPath()
    /// An older log waiting for "Undo … taken at …?" confirmation.
    @State private var pendingUndo: DoseInstance?

    private var cal: Calendar { PregnancyMath.calendar }
    private var today: Date { cal.startOfDay(for: store.now) }
    private var isToday: Bool { cal.isDate(selectedDay, inSameDayAs: today) }
    private var isFuture: Bool { selectedDay > today }

    private var owner: MedOwner { store.medsPerson }
    private var meds: [Medication] { store.meds(of: owner) }

    private func instances(on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: meds, logs: store.doseLogs)
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            Group {
                if meds.isEmpty {
                    emptyState
                } else {
                    content
                        .onDisappear {
                            // Leaving with a shift not saved yet: the tab bar asks Just today / Every day.
                            if store.scheduleChange?.kind == .shift { store.shiftNeedsAnswer = true }
                        }
                }
            }
            .navigationTitle("Meds today")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MedsRoute.self) { route in
                switch route {
                case .schedule(let who):
                    MedsOverviewView(owner: who)
                case .rules(let who, let focus):
                    MedsRoutinesView(owner: who, editing: true, focusName: focus, onApplied: {
                        if !path.isEmpty { path.removeLast() }
                    })
                }
            }
        }
        .sheet(isPresented: $showQuiz) {
            RoutineQuizView(owner: owner, template: nil, days: nil) { saved in
                showQuiz = false
                // A new routine goes straight on to Meds & routines, where she writes her meds.
                if saved != nil {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        path.append(MedsRoute.schedule(owner))
                    }
                }
            }
        }
        .sheet(isPresented: $showProgress) {
            HowItsGoingView(owner: owner) { med in
                showProgress = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    path.append(MedsRoute.schedule(med?.owner ?? owner))
                }
            }
        }
        .sheet(item: $sheetMed) { med in
            MedicationSheet(medication: med) { med in
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    path.append(MedsRoute.rules(med.owner, focus: med.shortName))
                }
            }
        }
        .fullScreenCover(item: $store.celebration) { celebration in
            SlotCompleteView(celebration: celebration, headline: celebrationHeadline(celebration),
                             subtitle: celebrationSubtitle(celebration)) {
                store.celebration = nil
            }
        }
        .overlay(alignment: .bottom) {
            // Hold the toast (and its timer) until the celebration screen is closed.
            if let toast = store.undoToast, store.celebration == nil {
                DarkToast(message: toast.message) {
                    store.undo(medicationID: toast.medicationID, scheduledAt: toast.scheduledAt)
                } onExpire: {
                    if store.undoToast?.id == toast.id { store.undoToast = nil }
                }
                .id(toast.id)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .duoBarClearance()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.undoToast?.id)
        .alert(pendingUndo.map(undoQuestion) ?? "", isPresented: Binding(
            get: { pendingUndo != nil },
            set: { if !$0 { pendingUndo = nil } }
        ), presenting: pendingUndo) { instance in
            Button("Undo", role: .destructive) {
                store.undo(instance)
                pendingUndo = nil
            }
            Button("Keep", role: .cancel) { pendingUndo = nil }
        } message: { instance in
            if let line = store.loggedByLine(instance.log) {
                Text(line)
            }
        }
        .onChange(of: DeepLinkRouter.shared.medsRequest) { _, _ in openFromLink() }
        .onAppear { if DeepLinkRouter.shared.pendingMeds { openFromLink() } }
        .onChange(of: today) { oldValue, newValue in
            // Follow the calendar across midnight when the user was looking at "today".
            if cal.isDate(selectedDay, inSameDayAs: oldValue) { selectedDay = newValue }
        }
    }

    // MARK: Deep link (carry://meds)

    /// Bumped to scroll the day list to the current or next dose.
    @State private var scrollRequest = 0

    /// Meds today at the top level, on today, scrolled to the dose that matters now.
    private func openFromLink() {
        DeepLinkRouter.shared.pendingMeds = false
        sheetMed = nil
        showProgress = false
        showQuiz = false
        path = NavigationPath()
        selectedDay = today
        scrollRequest += 1
    }

    /// The row id ("dose-…") of the dose due now, else the next one.
    private var focusRowID: String? {
        let list = instances(on: today)
        let carry = MedsEngine.carryOver(into: today, medications: meds, logs: store.doseLogs)
        let state = MedsEngine.rightNow(instances: list, now: store.now, carryOver: carry)
        let target = state.due.first(where: { list.contains($0) }) ?? state.next
            ?? list.first(where: \.isPending)
        return target.map { "dose-\($0.id)" }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = focusRowID else { return }
        Task { @MainActor in
            // Let the tab switch and the list settle first.
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let list = instances(on: selectedDay)
        AdaptiveColumns {
            PaneScroll(pane: .primary, spacing: 18) {
                NotificationsOffBanner()
                header
                weekStrip
                status(list)
                if isToday { nextCard }
            }
            .carryPullToRefresh { await refresh() }
            .background(Theme.dayCanvas)
        } secondary: {
            ScrollViewReader { proxy in
                PaneScroll(pane: .secondary, spacing: 14) {
                    // Meds & routines lives once, next to the title in the left pane.
                    Text(isToday ? "Today" : selectedDay.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.dayText)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.top, 6)
                    dayList(list)
                }
                .modifier(RevealRowPanel(proxy: proxy))
                .onChange(of: scrollRequest) { _, _ in scrollToFocus(proxy) }
                .onAppear { if scrollRequest > 0 { scrollToFocus(proxy) } }
            }
            .background(Theme.dayCanvas)
        } compact: {
            ScrollViewReader { proxy in
                PaneScroll(spacing: 18) {
                    NotificationsOffBanner()
                    header
                    weekStrip
                    status(list)
                    dayList(list)
                }
                .modifier(RevealRowPanel(proxy: proxy))
                .carryPullToRefresh { await refresh() }
                .onChange(of: scrollRequest) { _, _ in scrollToFocus(proxy) }
                .onAppear { if scrollRequest > 0 { scrollToFocus(proxy) } }
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
        }
        .background(Theme.dayCanvas.ignoresSafeArea())
    }

    /// "Meds today" + the streak summary line; Meds & routines sits top right.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.dayText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                schedulingLink
            }
            if owner != store.viewerRole {
                Text("\(store.name(for: owner))'s day")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
            }
            StreakChart(days: store.streak(owner).current, bars: store.streakBars(owner),
                        paused: store.celebration != nil) {
                Haptics.tap()
                showProgress = true
            }
            .padding(.top, -10)
        }
        .padding(.top, 8)
    }

    private var title: String {
        if isToday { return "Meds today" }
        return selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var schedulingLink: some View {
        NavigationLink(value: MedsRoute.schedule(owner)) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.daySecondary)
                .frame(width: 44, height: 44)
                .background(Theme.dayCard, in: .circle)
        }
        .accessibilityLabel("Meds & routines")
        .accessibilityIdentifier("meds-schedule")
    }

    private var weekStrip: some View {
        WeekStrip(selection: $selectedDay, today: today) { day in store.dayMark(owner, on: day) }
    }

    // MARK: Status

    private struct StatusText {
        var noFood: Bool; var trailing: String; var next: String
        var countdown: String? = nil; var minutesLeft = 0; var progress: Double? = nil
    }

    private func statusText(_ list: [DoseInstance]) -> StatusText {
        let carry = MedsEngine.carryOver(into: today, medications: meds, logs: store.doseLogs)
        let state = MedsEngine.rightNow(instances: list, now: store.now, carryOver: carry)
        var next: String
        if let due = state.due.first {
            next = "Due now: \(due.medication.shortName)"
        } else if let n = state.next {
            next = "Next: \(n.medication.shortName) at \(DayList.clock(n.anchor))"
        } else if state.allDone {
            next = "All done for today"
        } else {
            next = "Nothing else planned today"
        }
        switch state.food {
        case .noFood(let w):
            let left = max(0, Int((w.end.timeIntervalSince(store.now) / 60).rounded(.up)))
            let length = w.end.timeIntervalSince(w.start)
            return StatusText(noFood: true, trailing: "until \(DayList.clock(w.end))", next: next,
                              countdown: left >= 60 ? "\(left / 60) h \(left % 60) min" : "\(left) min",
                              minutesLeft: left,
                              progress: length > 0 ? store.now.timeIntervalSince(w.start) / length : nil)
        case .holdForDose(let i, _, _):
            next = "Take \(i.medication.shortName) first, then eat"
            return StatusText(noFood: true, trailing: "for now", next: next)
        case .foodOK(let window):
            return StatusText(noFood: false, trailing: window.map { "No food from \(DayList.clock($0.start))" } ?? "", next: next)
        }
    }

    @ViewBuilder
    private func status(_ list: [DoseInstance]) -> some View {
        if isToday {
            let s = statusText(list)
            VStack(spacing: 12) {
                FoodStatusCard(noFood: s.noFood, trailing: s.trailing, next: s.next,
                               countdown: s.countdown, remainingMinutes: s.minutesLeft, progress: s.progress)
                if let change = store.scheduleChange, change.placement == .top, change.owner == owner,
                   cal.isDate(change.date, inSameDayAs: selectedDay) {
                    ScheduleChangePanel(change: change)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.scheduleChange?.id)
        } else {
            let done = list.filter { !$0.isPending }.count
            HStack {
                Text(isFuture ? "Planned" : "\(done) of \(list.count) logged")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
                Spacer()
                Button("Back to today") {
                    Haptics.select()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selectedDay = today }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        }
    }

    /// Open Duo, left pane: the next dose with Taken, and "1 of 5" progress.
    @ViewBuilder
    private var nextCard: some View {
        let list = instances(on: today)
        let carry = MedsEngine.carryOver(into: today, medications: meds, logs: store.doseLogs)
        let state = MedsEngine.rightNow(instances: list, now: store.now, carryOver: carry)
        let target = state.due.first ?? state.next
        VStack(alignment: .leading, spacing: 14) {
            if let target {
                Text(state.due.isEmpty ? "Next" : "Due now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dayMuted)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.medication.shortName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.dayText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(DayList.clock(target.anchor))
                            .font(.system(size: 17))
                            .monospacedDigit()
                            .foregroundStyle(Theme.rose)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Haptics.success()
                        store.markTaken(target, at: store.now, placement: .top)
                    } label: {
                        Text("Taken")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 48)
                            .background(Theme.rose, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("meds-next-taken")
                }
            } else {
                Text(state.allDone ? "All done for today" : "Nothing else planned today")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(state.resolvedToday) of \(state.totalToday)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(state.resolvedToday)))
                    .foregroundStyle(Theme.daySecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.dayDivider)
                        Capsule().fill(Theme.greenCheck)
                            .frame(width: state.totalToday == 0 ? 0 : geo.size.width * CGFloat(state.resolvedToday) / CGFloat(state.totalToday))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(18)
        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.resolvedToday)
        .accessibilityIdentifier("meds-next-card")
    }

    // MARK: List

    @ViewBuilder
    private func dayList(_ list: [DoseInstance]) -> some View {
        if !store.hasRoutine(owner) {
            routinePrompt
        }
        MedsTodayList(
            instances: list,
            meals: shownMeals,
            day: selectedDay,
            owner: owner,
            canLog: !isFuture,
            now: isToday ? store.now : nil,
            actions: doseActions,
            onOpenMedication: { med in
                Haptics.tap()
                sheetMed = store.medications.first { $0.id == med.id } ?? med
            }
        )
    }

    /// Medications from before routines existed: offer to plan them around the day.
    private var routinePrompt: some View {
        Button {
            Haptics.tap()
            showQuiz = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan around your day")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.dayText)
                    Text("Tell Carry when you wake, eat and sleep.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.daySecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.rose)
            }
            .padding(16)
            .background(Theme.roseTint, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("meds-plan-routine")
    }

    /// Meals as a pending Shift my day would leave them.
    private var shownMeals: [ScheduleMeal] {
        if let change = store.scheduleChange, change.kind == .shift, change.owner == owner,
           cal.isDate(change.date, inSameDayAs: selectedDay) {
            return change.meals
        }
        return store.meals(for: owner, on: selectedDay)
    }

    private var doseActions: DoseActions {
        DoseActions(
            taken: { store.markTaken($0, at: $1, placement: .row($0.medication.id)) },
            skip: { store.skip($0) },
            undo: { instance in
                // Fresh logs undo straight away; older ones were probably right, so ask first.
                if let log = instance.log, Date.now.timeIntervalSince(log.loggedAt) > 10 * 60 {
                    Haptics.tap()
                    pendingUndo = instance
                } else {
                    store.undo(instance)
                }
            },
            changeTaken: { store.changeTakenTime($0, to: $1, placement: .row($0.medication.id)) },
            edit: { med in sheetMed = store.medications.first { $0.id == med.id } ?? med }
        )
    }

    private func undoQuestion(_ instance: DoseInstance) -> String {
        let name = instance.medication.shortName
        if let log = instance.log, log.status == .taken, let takenAt = log.takenAt {
            return "Undo \(name) taken at \(takenAt.formatted(date: .omitted, time: .shortened))?"
        }
        return "Undo \(name) skipped?"
    }

    private var emptyState: some View {
        ZStack {
            Theme.dayCanvas.ignoresSafeArea()
            CenteredScroll {
                VStack(spacing: 16) {
                    CarryEmptyMark(size: 56)
                        .padding(.bottom, 4)
                    Text(store.hasRoutine(owner) ? "Write your medications" : "Set up your routine")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.dayText)
                        .multilineTextAlignment(.center)
                    Text(store.hasRoutine(owner)
                         ? "Write them in one go with any rules about timing, food or each other. Carry works out the times."
                         : "A few questions about when you wake, eat and sleep. Then write your medications and Carry places every dose around your day.")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.daySecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        startAdd()
                    } label: {
                        Text(store.hasRoutine(owner) ? "Write my medications" : "Set up your routine")
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

    /// No routine yet: the quiz first (it hands over to Meds & routines). Otherwise straight there.
    /// Pull to refresh: fetch the partner's latest logs and recompute the day.
    private func refresh() async {
        store.reloadIfChangedExternally()
        store.now = .now
        SyncEngine.shared.refresh()
        try? await Task.sleep(for: .seconds(1))
    }

    private func startAdd() {
        Haptics.tap()
        if store.hasRoutine(owner) { path.append(MedsRoute.schedule(owner)) } else { showQuiz = true }
    }

    // MARK: Celebration wording

    private func celebrationHeadline(_ celebration: SlotCelebration) -> String {
        let taker = celebration.taker
        if store.isShared, taker != store.viewerRole {
            return "\(store.name(for: taker))'s \(celebration.slot.title.lowercased()) is done!"
        }
        // Mom-specific wording only for the mom.
        if taker == .mom { return "You're glowing, \(store.name(for: .mom))!" }
        return "Nicely done, \(store.name(for: .partner))!"
    }

    private func celebrationSubtitle(_ celebration: SlotCelebration) -> String {
        let percent = Int((celebration.progress * 100).rounded())
        if store.isShared, celebration.taker != store.viewerRole {
            return "\(percent)% of \(store.name(for: celebration.taker))'s doses logged today"
        }
        return "\(percent)% of today's doses logged"
    }
}

/// Scrolls a schedule-change panel that opens under a list row into view, so it is
/// never left below the screen edge (on the open iPhone Duo the list fills its pane).
extension EnvironmentValues {
    /// Scrolls the surrounding day list so the view with this id sits fully on screen.
    @Entry var revealInScroll: ((AnyHashable) -> Void)? = nil
}

private struct RevealRowPanel: ViewModifier {
    var proxy: ScrollViewProxy
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .environment(\.revealInScroll) { id in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .onChange(of: store.scheduleChange?.id) { _, id in
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
