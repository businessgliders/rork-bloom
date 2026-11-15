import SwiftUI

/// One routine's day: a slider along the top with a dot per item (dragging shifts it and everything after it,
/// keeping the gaps), a draggable list for reordering, and an inline warning with Undo / Keep after any change
/// that breaks a rule.
struct ScheduleEditorView: View {
    let templateID: UUID

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScheduleTemplate?
    @State private var original: ScheduleTemplate?
    /// Before the last change, for Undo.
    @State private var snapshot: ScheduleTemplate?
    /// Rules the last change broke.
    @State private var fresh: [RuleViolation] = []
    @State private var showQuiz = false
    @State private var confirmRecalculate = false

    private var dirty: Bool { draft != original }

    var body: some View {
        Group {
            if let draft {
                content(draft)
            } else {
                ContentUnavailableView("Routine not found", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .background(BloomBackground())
        .navigationTitle(draft.map { ScheduleTemplate.daysLabel($0.days) } ?? "Routine")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        Haptics.tap()
                        withAnimation { draft = original; fresh = []; snapshot = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.blushDeep)
                        .accessibilityIdentifier("editor-save")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.templates) { _, _ in
            // A remote change while nothing is being edited.
            if !dirty { load(force: true) }
        }
        .sheet(isPresented: $showQuiz) {
            if let draft {
                RoutineQuizView(owner: draft.owner, template: store.templates.first { $0.id == draft.id }) { _ in
                    showQuiz = false
                    load(force: true)
                }
            }
        }
        .confirmationDialog("Recalculate every time from your rules?", isPresented: $confirmRecalculate, titleVisibility: .visible) {
            Button("Recalculate") { recalculate() }
        } message: {
            Text("Times you moved by hand go back to the earliest time that keeps every rule.")
        }
    }

    // MARK: Layout

    private func content(_ t: ScheduleTemplate) -> some View {
        let items = timeline(t)
        let violations = store.violations(in: t)
        return List {
            Section {
                DaySlider(items: items, wake: t.wake.minutesFromMidnight, bed: t.bed.minutesFromMidnight) { id, delta in
                    shift(id, by: delta)
                }
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            } footer: {
                Text("Drag a dot to move it and everything after it. The gaps stay the same.")
                    .font(.bloom(.caption))
            }

            if !fresh.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(fresh) { ViolationCard(violation: $0) }
                        HStack(spacing: 10) {
                            Button {
                                undo()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(BloomSoftButtonStyle())
                            .accessibilityIdentifier("editor-undo")
                            Button {
                                Haptics.tap()
                                withAnimation { fresh = [] ; snapshot = nil }
                            } label: {
                                Text("Keep").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(BloomSoftButtonStyle(tint: Theme.text))
                            .accessibilityIdentifier("editor-keep")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if !violations.isEmpty {
                Section("Rules not met") {
                    ForEach(violations) { v in
                        Text(v.message)
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.coralDeep)
                    }
                }
            }

            Section {
                ForEach(items.filter { $0.kind != .wake && $0.kind != .bed }) { item in
                    ItemRow(item: item)
                        .moveDisabled(!item.isDose)
                }
                .onMove { source, destination in move(source, to: destination) }
            } header: {
                Text("Order")
            } footer: {
                Text("Drag a medication to a new spot. It goes halfway between its new neighbours.")
                    .font(.bloom(.caption))
            }

            Section("Days") {
                DayChips(days: Binding(get: { draft?.days ?? [] }, set: { setDays($0) }),
                         taken: store.takenDays(for: t.owner, excluding: t.id))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                Button {
                    Haptics.tap()
                    if dirty { save() }
                    showQuiz = true
                } label: {
                    Label("Edit wake, meals and bedtime", systemImage: "sun.horizon")
                }
                Button {
                    confirmRecalculate = true
                } label: {
                    Label("Recalculate from my rules", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .tint(Theme.blushDeep)
        }
        .scrollContentBackground(.hidden)
        .duoListClearance()
        .environment(\.editMode, .constant(.active))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items.map(\.minutes))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: fresh.map(\.id))
    }

    // MARK: Model

    fileprivate struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case wake, bed, meal, dose }
        var kind: Kind
        var id: UUID
        var name: String
        var minutes: Int
        var duration: Int = 0
        var noFood: Bool = false
        var pinned: Bool = false
        var isDose: Bool { kind == .dose }
    }

    private func timeline(_ t: ScheduleTemplate) -> [Item] {
        var items: [Item] = [Item(kind: .wake, id: t.id, name: "Wake up", minutes: t.wake.minutesFromMidnight)]
        items += t.meals.map { Item(kind: .meal, id: $0.id, name: $0.name, minutes: $0.time.minutesFromMidnight, duration: $0.durationMinutes) }
        let names = store.medicationNames
        let noFood = Set(store.rules(for: t.owner).filter(\.isNoFood).map(\.subjectID))
        items += t.doses.map {
            Item(kind: .dose, id: $0.medicationID, name: names[$0.medicationID] ?? "Medication", minutes: $0.time.minutesFromMidnight,
                 noFood: noFood.contains($0.medicationID), pinned: $0.pinned)
        }
        items.append(Item(kind: .bed, id: UUID(uuidString: "00000000-0000-0000-0000-00000000BED0")!, name: "Bedtime", minutes: t.bed.minutesFromMidnight))
        return items.sorted { lhs, rhs in
            if lhs.minutes != rhs.minutes { return lhs.minutes < rhs.minutes }
            return rank(lhs.kind) < rank(rhs.kind)
        }
    }

    private func rank(_ kind: Item.Kind) -> Int {
        switch kind { case .wake: 0; case .dose: 1; case .meal: 2; case .bed: 3 }
    }

    private func write(_ items: [Item], into t: inout ScheduleTemplate) {
        for item in items {
            let time = DoseTime(minutes: min(max(item.minutes, 0), 1439))
            switch item.kind {
            case .wake: t.wake = time
            case .bed: t.bed = time
            case .meal: if let i = t.meals.firstIndex(where: { $0.id == item.id }) { t.meals[i].time = time }
            case .dose: if let i = t.doses.firstIndex(where: { $0.medicationID == item.id }) { t.doses[i].time = time }
            }
        }
        t.meals.sort { $0.time < $1.time }
    }

    // MARK: Actions

    private func load() { load(force: false) }

    private func load(force: Bool) {
        guard force || draft == nil, let t = store.templates.first(where: { $0.id == templateID }) else { return }
        draft = t
        original = t
        fresh = []
        snapshot = nil
    }

    /// Applies a change, then re-checks every rule; rules the change newly broke get Undo / Keep.
    private func change(_ mutate: (inout ScheduleTemplate) -> Void) {
        guard var t = draft else { return }
        let before = t
        let brokenBefore = Set(store.violations(in: before).map(\.id))
        mutate(&t)
        guard t != before else { return }
        draft = t
        let newlyBroken = store.violations(in: t).filter { !brokenBefore.contains($0.id) }
        if newlyBroken.isEmpty {
            Haptics.select()
            // A change that also fixed things clears the pending warning.
            fresh = fresh.filter { f in store.violations(in: t).contains { $0.id == f.id } }
            if fresh.isEmpty { snapshot = nil }
        } else {
            Haptics.warning()
            if fresh.isEmpty { snapshot = before }
            fresh = store.violations(in: t).filter { v in newlyBroken.contains { $0.id == v.id } || fresh.contains { $0.id == v.id } }
        }
    }

    private func shift(_ id: UUID, by delta: Int) {
        guard delta != 0 else { return }
        change { t in
            var items = timeline(t)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            // Bedtime stays unless something would pass it.
            let bedIndex = items.firstIndex { $0.kind == .bed }
            let shifted = ScheduleEngine.shift(items.map(\.minutes), from: index, by: delta)
            for i in items.indices where i != bedIndex || index == bedIndex { items[i].minutes = shifted[i] }
            if let bedIndex, index != bedIndex {
                let latest = items.filter { $0.kind != .bed }.map { $0.minutes + $0.duration }.max() ?? 0
                items[bedIndex].minutes = max(items[bedIndex].minutes, ScheduleEngine.roundUp(latest))
            }
            // Never before midnight or after 23:55.
            for i in items.indices { items[i].minutes = min(max(items[i].minutes, 0), 1435) }
            write(items, into: &t)
        }
    }

    private func move(_ source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        change { t in
            var list = timeline(t).filter { $0.kind != .wake && $0.kind != .bed }
            guard list.indices.contains(from), list[from].isDose else { return }
            let minutes = ScheduleEngine.timeAfterMove(list.map(\.minutes), from: from, to: destination)
            let lower = t.wake.minutesFromMidnight
            list[from].minutes = min(max(minutes, lower), max(t.bed.minutesFromMidnight, lower))
            if let i = t.doses.firstIndex(where: { $0.medicationID == list[from].id }) {
                t.doses[i].time = DoseTime(minutes: list[from].minutes)
            }
        }
    }

    private func setDays(_ days: Set<Int>) {
        guard !days.isEmpty else { return }
        Haptics.select()
        draft?.days = days
    }

    private func undo() {
        Haptics.tap()
        withAnimation {
            if let snapshot { draft = snapshot }
            snapshot = nil
            fresh = []
        }
    }

    private func recalculate() {
        guard let t = draft else { return }
        Haptics.tap()
        let generated = store.generate(t)
        withAnimation {
            draft = generated.template
            fresh = []
            snapshot = nil
        }
    }

    private func save() {
        guard let t = draft else { return }
        store.saveTemplate(t, regenerate: false)
        Haptics.success()
        load(force: true)
    }
}

// MARK: - Slider

private struct DaySlider: View {
    var items: [ScheduleEditorView.Item]
    var wake: Int
    var bed: Int
    var onShift: (UUID, Int) -> Void

    @State private var dragging: UUID?
    @State private var dragDelta = 0

    private var lo: Int { (min(wake, items.map(\.minutes).min() ?? wake) / 60) * 60 }
    private var hi: Int { max(lo + 120, ((max(bed, items.map { $0.minutes + $0.duration }.max() ?? bed) + 59) / 60) * 60) }

    /// Items at or after the dragged one move with it.
    private func offset(for item: ScheduleEditorView.Item) -> Int {
        guard let dragging, let anchor = items.firstIndex(where: { $0.id == dragging }),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return 0 }
        if item.kind == .bed, items[anchor].kind != .bed { return 0 }
        return index >= anchor ? dragDelta : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                let span = CGFloat(hi - lo)
                let start = lo
                let x: (Int) -> CGFloat = { CGFloat($0 - start) / span * width }
                ZStack(alignment: .topLeading) {
                    // Track
                    Capsule()
                        .fill(Theme.ringTrack)
                        .frame(width: width, height: 6)
                        .offset(y: trackY - 3)
                    Capsule()
                        .fill(Theme.blushSoft)
                        .frame(width: max(0, x(bed) - x(wake + offset(for: items[0]))), height: 6)
                        .offset(x: x(wake + offset(for: items[0])), y: trackY - 3)

                    // Meals: sage bars under the track
                    ForEach(items.filter { $0.kind == .meal }) { meal in
                        let m = meal.minutes + offset(for: meal)
                        Capsule()
                            .fill(Theme.sage)
                            .frame(width: max(8, x(m + meal.duration) - x(m)), height: 10)
                            .offset(x: x(m), y: trackY + 10)
                            .gesture(drag(meal, width: width, span: span))
                            .accessibilityLabel("\(meal.name), \(ScheduleEngine.clock(meal.minutes))")
                    }

                    // Dots: ones at (nearly) the same time stack upward in lanes so none hides another.
                    let lane = lanes(width: width, span: span)
                    ForEach(items.filter { $0.kind != .meal }) { item in
                        let m = item.minutes + offset(for: item)
                        let active = dragging == item.id
                        Circle()
                            .fill(color(item))
                            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                            .frame(width: active ? 24 : 18, height: active ? 24 : 18)
                            .position(x: x(m), y: trackY - CGFloat(lane[item.id] ?? 0) * 20)
                            .gesture(drag(item, width: width, span: span))
                            .accessibilityLabel("\(item.name), \(ScheduleEngine.clock(item.minutes))")
                            .accessibilityAdjustableAction { direction in
                                onShift(item.id, direction == .increment ? 15 : -15)
                            }
                            .accessibilityIdentifier(item.kind == .wake ? "slider-wake" : "slider-\(item.name)")
                    }

                    // Bubble while dragging
                    if let dragging, let item = items.first(where: { $0.id == dragging }) {
                        let m = item.minutes + dragDelta
                        Text("\(item.name) \(ScheduleEngine.clock(m))")
                            .font(.bloom(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.canvas)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.text, in: .capsule)
                            .fixedSize()
                            .position(x: min(max(x(m), 60), width - 60), y: 8)
                    }
                }
            }
            .frame(height: trackY + 26)

            HStack {
                Text(ScheduleEngine.clock(lo))
                Spacer()
                Text(ScheduleEngine.clock((lo + hi) / 2))
                Spacer()
                Text(ScheduleEngine.clock(hi))
            }
            .font(.bloom(.caption2))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 14) {
                legend(Theme.peach, "Wake / bed")
                legend(Theme.blush, "Medication")
                legend(Theme.coral, "No food rule")
                legend(Theme.sage, "Meal")
            }
            .font(.bloom(.caption2))
            .foregroundStyle(Theme.textSecondary)
        }
        .sensoryFeedback(.selection, trigger: dragDelta)
    }

    private let trackY: CGFloat = 68

    /// Lane 0 sits on the track; a dot closer than one dot-width to the previous one in a lane goes up a lane (max 3).
    private func lanes(width: CGFloat, span: CGFloat) -> [UUID: Int] {
        let gap = 22 / max(width, 1) * span
        var lastInLane: [CGFloat] = []
        var result: [UUID: Int] = [:]
        let dots = items.filter { $0.kind != .meal }
            .map { ($0.id, CGFloat($0.minutes + offset(for: $0))) }
            .sorted { $0.1 < $1.1 }
        for (id, m) in dots {
            let lane = lastInLane.firstIndex(where: { m - $0 >= gap }) ?? min(lastInLane.count, 2)
            if lane < lastInLane.count { lastInLane[lane] = m } else { lastInLane.append(m) }
            result[id] = lane
        }
        return result
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }

    private func color(_ item: ScheduleEditorView.Item) -> Color {
        switch item.kind {
        case .wake, .bed: Theme.peach
        case .meal: Theme.sage
        case .dose: item.noFood ? Theme.coral : Theme.blush
        }
    }

    private func drag(_ item: ScheduleEditorView.Item, width: CGFloat, span: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragging = item.id
                let minutes = Double(value.translation.width / max(width, 1) * span)
                dragDelta = Int((minutes / 5).rounded()) * 5
            }
            .onEnded { _ in
                let delta = dragDelta
                dragging = nil
                dragDelta = 0
                onShift(item.id, delta)
            }
    }
}

// MARK: - Rows

private struct ItemRow: View {
    var item: ScheduleEditorView.Item

    var body: some View {
        HStack(spacing: 12) {
            Text(ScheduleEngine.clock(item.minutes))
                .font(.bloom(.subheadline))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.bloom(.body, weight: item.isDose ? .semibold : .regular))
                    .foregroundStyle(item.isDose ? Theme.text : Theme.sageDeep)
                if item.kind == .meal {
                    Text("Meal · \(ScheduleEngine.duration(item.duration))")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                } else if item.pinned {
                    Text("Fixed time")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("editor-row-\(item.name)")
    }
}

/// Weekday chips. Days another routine of this person uses are disabled.
struct DayChips: View {
    @Binding var days: Set<Int>
    var taken: Set<Int>

    var body: some View {
        let symbols = PregnancyMath.calendar.veryShortWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(ScheduleTemplate.orderedDays, id: \.self) { day in
                let on = days.contains(day)
                let blocked = taken.contains(day)
                Button {
                    if on { days.remove(day) } else if !blocked { days.insert(day) }
                } label: {
                    Text(symbols[day])
                        .font(.bloom(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(on ? .white : (blocked ? Color(uiColor: .tertiaryLabel) : Theme.blushDeep))
                        .background(on ? Theme.blush : (blocked ? Theme.surfaceMuted : Theme.blushSoft), in: .circle)
                }
                .buttonStyle(PressableStyle())
                .disabled(blocked && !on)
                .accessibilityLabel(PregnancyMath.calendar.weekdaySymbols[day] + (blocked ? ", used by another routine" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
