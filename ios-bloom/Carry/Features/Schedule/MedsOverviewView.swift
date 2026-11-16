import SwiftUI

/// Meds & routines (boards 2, 3, 4c, 6).
/// Routine chips, a collapsible "My rules" card with her own words, then the day as one list
/// (wake, meals, doses, bedtime). Wake / meal / bed times open an inline wheel; med times move by
/// dragging the grip into the green band. First time (no meds yet) it goes straight to the editor.
struct MedsOverviewView: View {
    var owner: MedOwner
    @Environment(AppStore.self) private var store

    @State private var setup: Bool?
    @State private var selectedRoutine: UUID?
    @State private var rulesOpen = false
    @State private var showEditor = false
    @State private var sheetMed: Medication?
    @State private var openWheel: Kind?
    @State private var shiftOpen = false

    // Drag
    @State private var drag: DragState?
    @State private var pendingDrop: PendingDrop?

    // After a change
    @State private var changed: [UUID: Int] = [:]
    @State private var toast: String?
    @State private var undoText: String?
    @State private var beforeTimes: [UUID: Int] = [:]
    @State private var beforeText: String?

    enum Kind: Hashable { case wake, bed, meal(UUID), dose(UUID) }

    struct Entry: Identifiable {
        var kind: Kind
        var minutes: Int
        var name: String
        var taken = false
        var id: Kind { kind }
    }

    struct DragState {
        var id: UUID
        var name: String
        var bands: DropBands
        var translation: CGFloat = 0
        var minute: Int
    }

    struct PendingDrop: Equatable {
        var id: UUID
        var name: String
        var option: MoveOption
    }

    private static let bandHeight: CGFloat = 52

    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }

    private var routine: ScheduleTemplate? {
        let templates = store.templates(for: owner)
        return templates.first { $0.id == selectedRoutine } ?? store.activeTemplate(for: owner, on: store.now) ?? templates.first
    }

    /// The next day (from today) that follows the selected routine.
    private var day: Date {
        let today = PregnancyMath.calendar.startOfDay(for: store.now)
        guard let r = routine else { return today }
        for i in 0..<7 {
            let d = PregnancyMath.addDays(i, to: today)
            if store.activeTemplate(for: owner, on: d)?.id == r.id { return d }
        }
        return today
    }

    var body: some View {
        Group {
            if setup == true {
                MedsRoutinesView(owner: owner, onApplied: {
                    withAnimation(.smooth(duration: 0.4)) { setup = false }
                })
            } else if setup == false {
                overview
            } else {
                Color.clear
            }
        }
        .onAppear {
            if setup == nil { setup = !store.currentMedications(for: owner).contains { $0.managed } }
        }
    }

    private var overview: some View {
        AdaptiveColumns {
            PaneScroll(pane: .primary, spacing: 16) {
                header
                chips
                rulesCard(forceOpen: true)
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
        } secondary: {
            PaneScroll(pane: .secondary, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(routine?.displayName ?? "Every day")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.dayText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    moveDayButton
                }
                shiftStrip
                caption(showMoveDay: false)
                list
            }
            .scrollDisabled(drag != nil)
            .background(Theme.dayCanvas.ignoresSafeArea())
        } compact: {
            PaneScroll(spacing: 16) {
                header
                chips
                rulesCard(forceOpen: false)
                caption(showMoveDay: true)
                shiftStrip
                list
            }
            .scrollDisabled(drag != nil)
            .background(Theme.dayCanvas.ignoresSafeArea())
        }
        .navigationTitle("Meds & routines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("") }
        }
        // While a medication is lifted the tab bar (the Duo's side bar too) steps away; it returns on drop or cancel.
        .toolbar(drag != nil ? .hidden : .visible, for: .tabBar)
        .animation(.easeInOut(duration: 0.25), value: drag == nil)
        .safeAreaInset(edge: .bottom) {
            if let pendingDrop {
                dropBar(pendingDrop)
                    .duoBarClearance()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast {
                DarkToast(message: toast, onAction: undoEditorChange, onExpire: {
                    withAnimation { self.toast = nil }
                })
                .padding(.horizontal, DayList.side)
                .padding(.bottom, 8)
                .duoBarClearance()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: pendingDrop)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: toast)
        .navigationDestination(isPresented: $showEditor) {
            MedsRoutinesView(owner: owner, editing: true, onApplied: editorApplied)
        }
        .sheet(item: $sheetMed) { med in
            MedicationSheet(medication: med) { _ in
                sheetMed = nil
                openEditor()
            }
        }
        .onAppear {
            if selectedRoutine == nil { selectedRoutine = store.activeTemplate(for: owner, on: store.now)?.id }
        }
        .onChange(of: selectedRoutine) {
            openWheel = nil
            pendingDrop = nil
            changed = [:]
        }
        .onDisappear {
            if case .routine = store.scheduleChange?.placement { store.scheduleChange = nil }
            if store.scheduleChange?.kind == .shift { store.scheduleChange = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Meds & routines")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.dayText)
                .accessibilityAddTraits(.isHeader)
            if !isViewer {
                Text("\(store.name(for: owner))'s plan")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine, showTimeCards: false)
    }

    // MARK: My rules

    private var ruleCounts: (meds: Int, rules: Int) {
        let text = store.medsTextOrFallback(for: owner)
        // "Progesterone a.m." on its own line is a name, not a rule.
        let names = Set(store.knownMedNames(owner).flatMap(MedNameMatch.variants).map { $0.lowercased() })
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let medLines = lines.filter { names.contains($0.lowercased()) }.count
        let meds = store.currentMedications(for: owner).filter(\.managed).count
        return (meds, max(0, lines.count - medLines))
    }

    private var rulesText: AttributedString {
        var a = AttributedString(store.medsTextOrFallback(for: owner).trimmingCharacters(in: .whitespacesAndNewlines))
        a.foregroundColor = Theme.dayText
        a.font = .system(size: 17)
        let names = store.knownMedNames(owner).flatMap(MedNameMatch.variants).sorted { $0.count > $1.count }
        for name in names {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from..<a.endIndex].range(of: name, options: .caseInsensitive) {
                if a[r].foregroundColor != Theme.rose {
                    a[r].foregroundColor = Theme.rose
                    a[r].font = .system(size: 17, weight: .semibold)
                }
                from = r.upperBound
            }
        }
        return a
    }

    private func rulesCard(forceOpen: Bool) -> some View {
        let open = forceOpen || rulesOpen
        let counts = ruleCounts
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !forceOpen else { return }
                Haptics.select()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { rulesOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My rules")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.dayText)
                        Text("\(counts.meds) medication\(counts.meds == 1 ? "" : "s") · \(counts.rules) rule\(counts.rules == 1 ? "" : "s")")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.dayMuted)
                    }
                    Spacer(minLength: 8)
                    if !forceOpen {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.dayMuted)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, forceOpen ? 16 : 6)
                .padding(.vertical, 8)
                .frame(minHeight: DayList.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("my-rules-card")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                DayDivider(inset: 16)
                VStack(alignment: .leading, spacing: 14) {
                    Text(rulesText)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        Haptics.tap()
                        openEditor()
                    } label: {
                        Text("Edit rules")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.rose)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.roseTint, in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("edit-meds-rules")
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .clipShape(.rect(cornerRadius: Theme.dayRadius, style: .continuous))
    }

    // MARK: Caption + move whole day

    @ViewBuilder
    private func caption(showMoveDay: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let drag {
                    Text("Moving \(Text(drag.name).bold()). Drop it anywhere in the green.")
                } else {
                    Text("Drag a handle to change a time")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(drag == nil ? Theme.dayMuted : Theme.dayText)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showMoveDay && drag == nil { moveDayButton }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 32)
    }

    private var moveDayButton: some View {
        Button {
            Haptics.select()
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                shiftOpen.toggle()
                if !shiftOpen, store.scheduleChange?.kind == .shift { store.scheduleChange = nil }
            }
        } label: {
            Text(shiftOpen ? "Close" : "Move whole day")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("move-whole-day")
    }

    private var currentShift: Int {
        store.scheduleChange?.kind == .shift ? store.scheduleChange?.shift ?? 0 : 0
    }

    @ViewBuilder
    private var shiftStrip: some View {
        if shiftOpen {
            let bounds = store.shiftBounds(owner, day: day)
            let total = currentShift
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    shiftButton("Earlier", icon: "minus", enabled: bounds.map { total - 15 >= $0.lowerBound } ?? false) { shift(by: -15) }
                    Text(total == 0 ? "Every time still to come" : "\(ScheduleEngine.duration(abs(total))) \(total < 0 ? "earlier" : "later")")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dayText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                    shiftButton("Later", icon: "plus", enabled: bounds.map { total + 15 <= $0.upperBound } ?? false) { shift(by: 15) }
                }
                if let change = store.scheduleChange, change.kind == .shift {
                    ScheduleChangePanel(change: change)
                }
            }
            .padding(12)
            .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func shiftButton(_ label: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text("15 min")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.rose)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.roseTint, in: .capsule)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel("\(label) by 15 minutes")
        .accessibilityIdentifier("shift-\(label.lowercased())")
    }

    private func shift(by delta: Int) {
        Haptics.select()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            store.proposeShift(owner, day: day, by: currentShift + delta)
            if store.scheduleChange?.kind == .shift { store.scheduleChange?.asked = true }
        }
    }

    // MARK: List

    /// The routine with a pending wake / meal / bed change applied.
    private func shown(_ t: ScheduleTemplate) -> ScheduleTemplate {
        guard let change = store.scheduleChange, change.placement == .routine(t.id), let draft = change.draft else { return t }
        return draft
    }

    private var entries: [Entry] {
        guard let r = routine else { return [] }
        let t = shown(r)
        var out: [Entry] = [Entry(kind: .wake, minutes: t.wake.minutesFromMidnight, name: "Wake up")]
        for meal in t.meals {
            out.append(Entry(kind: .meal(meal.id), minutes: meal.time.minutesFromMidnight, name: meal.name))
        }
        if let s = store.dayState(owner, on: day) {
            let names = store.medicationNames
            var times = s.times
            if store.scheduleChange?.kind == .shift { times.merge(store.scheduleChange?.times ?? [:]) { _, new in new } }
            if let pendingDrop { times.merge(pendingDrop.option.times) { _, new in new } }
            for (id, m) in times {
                out.append(Entry(kind: .dose(id), minutes: m, name: names[id] ?? "Medication", taken: s.fixed.contains(id)))
            }
        }
        let bed = t.bed.minutesFromMidnight
        out.append(Entry(kind: .bed, minutes: bed < t.wake.minutesFromMidnight ? bed + 1440 : bed, name: "Bedtime"))
        return out.sorted { a, b in
            if a.minutes != b.minutes { return a.minutes < b.minutes }
            return order(a.kind) < order(b.kind)
        }
    }

    private func order(_ k: Kind) -> Int {
        switch k {
        case .wake: 0
        case .meal: 1
        case .dose: 2
        case .bed: 3
        }
    }

    private var list: some View {
        let items = entries
        return DayCard {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { DayDivider(inset: 16).opacity(drag == nil ? 1 : 0.45) }
                row(entry)
                if openWheel == entry.kind, let r = routine {
                    wheel(entry.kind, original: r)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: items.map(\.id))
        .accessibilityIdentifier("routine-day-list")
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry.kind {
        case .dose(let id):
            medRow(entry, id: id)
        default:
            anchorRow(entry)
                .opacity(drag == nil ? 1 : 0.45)
        }
    }

    private func anchorRow(_ entry: Entry) -> some View {
        let isMeal: Bool = { if case .meal = entry.kind { return true }; return false }()
        let isSnack = entry.name.caseInsensitiveCompare("Snack") == .orderedSame
        return DayRow(
            time: ScheduleEngine.clock(entry.minutes % 1440),
            dot: isMeal ? Theme.greenDot : Theme.neutralDot,
            name: entry.name,
            timeColor: openWheel == entry.kind ? Theme.rose : nil,
            timeAction: {
                Haptics.select()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    openWheel = openWheel == entry.kind ? nil : entry.kind
                }
            },
            identifier: entry.name
        )
        .contextMenu {
            if let r = routine {
                let t = shown(r)
                if isMeal && isSnack, case .meal(let mealID) = entry.kind {
                    Button(role: .destructive) {
                        var e = t
                        e.meals.removeAll { $0.id == mealID }
                        openWheel = nil
                        store.proposeRoutineChange(original: r, edited: e)
                    } label: { Label("Remove snack", systemImage: "minus.circle") }
                } else if isMeal && !t.meals.contains(where: { $0.name.caseInsensitiveCompare("Snack") == .orderedSame }) {
                    Button {
                        var e = t
                        let snack = ScheduleMeal(name: "Snack", time: DoseTime(hour: 15, minute: 30), durationMinutes: 15)
                        e.meals.append(snack)
                        store.proposeRoutineChange(original: r, edited: e)
                        openWheel = .meal(snack.id)
                    } label: { Label("Add a snack", systemImage: "plus.circle") }
                }
            }
        }
    }

    private func wheel(_ kind: Kind, original: ScheduleTemplate) -> some View {
        let t = shown(original)
        let time: DoseTime? = {
            switch kind {
            case .wake: t.wake
            case .bed: t.bed
            case .meal(let id): t.meals.first { $0.id == id }?.time
            case .dose: nil
            }
        }()
        return VStack(spacing: 0) {
            if let time {
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
                        case .dose: return
                        }
                        store.proposeRoutineChange(original: original, edited: e)
                    }
                ), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 150)
                .clipped()
                .accessibilityIdentifier("time-wheel")
            }
            Button("Done") {
                Haptics.select()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { openWheel = nil }
            }
            .font(.system(size: 17, weight: .semibold))
            .tint(Theme.rose)
            .frame(minHeight: 44)
            .accessibilityIdentifier("picker-done")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: Med rows + drag

    /// One structure whether lifted or not, so the grip's drag gesture survives the bands appearing.
    private func medRow(_ entry: Entry, id: UUID) -> some View {
        let d = drag?.id == id ? drag : nil
        let bands = d?.bands
        let safe = bands?.safe
        let g = bands.map(zoneHeight) ?? 0
        let rowH = DayList.rowHeight
        let center = bands.map { position($0.current, bands: $0) + (d?.translation ?? 0) } ?? 0
        return VStack(spacing: d == nil ? 0 : 6) {
            if let safe, let bands {
                terraBand("Before \(ScheduleEngine.clock(safe.lowerBound)) · \(bands.beforeReason ?? "Another rule can't be kept")")
                    .transition(.opacity)
            }
            ZStack(alignment: .top) {
                if let safe, let bands {
                    greenBand(safe: safe, current: bands.current)
                        .padding(.vertical, rowH / 2 - 6)
                        .transition(.opacity)
                }
                plainMedRow(entry, id: id, lifted: d != nil, minute: d?.minute)
                    .offset(y: safe != nil ? center : (d.map { $0.translation / 4 } ?? 0))
            }
            .frame(height: safe != nil ? g + rowH : nil, alignment: .top)
            if let safe, let bands {
                terraBand("After \(ScheduleEngine.clock(safe.upperBound)) · \(bands.afterReason ?? "Another rule can't be kept")")
                    .transition(.opacity)
            } else if d != nil {
                terraBand("Nothing else fits on this day")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, d == nil ? 0 : 8)
        .padding(.vertical, d == nil ? 0 : 8)
        .opacity(drag == nil || d != nil ? 1 : 0.45)
        .background(d == nil && (changed[id] != nil || pendingDrop?.id == id) ? Theme.greenTint : .clear)
        .zIndex(d == nil ? 0 : 1)
    }

    private func plainMedRow(_ entry: Entry, id: UUID, lifted: Bool, minute: Int?) -> some View {
        let was: String? = {
            if lifted { return nil }
            if let old = changed[id] { return "was \(ScheduleEngine.clock(old).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))" }
            return nil
        }()
        return DayRow(
            time: ScheduleEngine.clock((minute ?? entry.minutes) % 1440),
            dot: entry.taken ? Theme.greenDot : Theme.rose,
            name: entry.name,
            muted: entry.taken,
            timeColor: lifted ? Theme.rose : nil,
            nameAction: {
                guard drag == nil else { return }
                Haptics.tap()
                sheetMed = store.medications.first { $0.id == id }
            },
            identifier: entry.name,
            timeNote: was
        ) {
            if !entry.taken && isViewerOrEditor {
                grip(id: id, name: entry.name)
            }
        }
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.dayCard)
                    .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            }
        }
        .overlay {
            if lifted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.rose, lineWidth: 2)
            }
        }
    }

    private var isViewerOrEditor: Bool { true }

    private func grip(id: UUID, name: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.dayMuted)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in dragChanged(id: id, name: name, translation: value.translation.height) }
                    .onEnded { _ in dragEnded() }
            )
            .accessibilityLabel("Move \(name)")
            .accessibilityHint("Drag up or down to change the time")
            .accessibilityIdentifier("grip-\(name)")
    }

    private func zoneHeight(_ bands: DropBands) -> CGFloat {
        guard let safe = bands.safe else { return DayList.rowHeight }
        let span = CGFloat(safe.upperBound - safe.lowerBound)
        return min(max(span * 0.8, 96), 260)
    }

    /// Where `m` sits inside the green band, from 0 (top) to G (bottom).
    private func position(_ m: Int, bands: DropBands) -> CGFloat {
        guard let safe = bands.safe else { return 0 }
        let g = zoneHeight(bands)
        let span = CGFloat(safe.upperBound - safe.lowerBound)
        guard span > 0 else { return g / 2 }
        return min(max(CGFloat(m - safe.lowerBound) / span * g, 0), g)
    }

    private func minute(at c: CGFloat, bands: DropBands) -> Int {
        guard let safe = bands.safe else { return bands.current }
        let g = zoneHeight(bands)
        let span = CGFloat(safe.upperBound - safe.lowerBound)
        let raw: CGFloat
        if c < 0 {
            raw = CGFloat(safe.lowerBound) + c * 1.5
        } else if c > g {
            raw = CGFloat(safe.upperBound) + (c - g) * 1.5
        } else {
            raw = span > 0 ? CGFloat(safe.lowerBound) + c / g * span : CGFloat(safe.lowerBound)
        }
        let step = CGFloat(ScheduleEngine.step)
        return Int((raw / step).rounded() * step)
    }

    private func dragChanged(id: UUID, name: String, translation: CGFloat) {
        if drag == nil {
            guard pendingDrop == nil, let bands = store.dropBands(owner: owner, day: day, medicationID: id) else { return }
            Haptics.tap()
            openWheel = nil
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                drag = DragState(id: id, name: name, bands: bands, minute: bands.current)
            }
            return
        }
        guard var d = drag, d.id == id else { return }
        d.translation = translation
        let c = position(d.bands.current, bands: d.bands) + translation
        let m = min(max(minute(at: c, bands: d.bands), 0), 1439)
        if m != d.minute { Haptics.select() }
        d.minute = m
        drag = d
    }

    private func dragEnded() {
        guard let d = drag else { return }
        let valid = d.bands.safe?.contains(d.minute) == true && d.minute != d.bands.current
        let option = d.bands.options[d.minute]
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            if valid, let option {
                Haptics.success()
                pendingDrop = PendingDrop(id: d.id, name: d.name, option: option)
            } else if d.minute != d.bands.current {
                Haptics.warning()
            }
            drag = nil
        }
    }

    private func greenBand(safe: ClosedRange<Int>, current: Int) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.greenTint.opacity(0.7))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.greenDot, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .overlay(alignment: .topLeading) {
                Text("Safe to drop · \(ScheduleEngine.clock(safe.lowerBound)) to \(ScheduleEngine.clock(safe.upperBound))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.greenText)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("Was \(ScheduleEngine.clock(current))")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.greenText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .accessibilityIdentifier("safe-band")
    }

    private func terraBand(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.terraDot).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.terraText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Self.bandHeight)
        .background(Theme.terraTint, in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Drop bar

    private var justLabel: String {
        PregnancyMath.calendar.isDateInToday(day) ? "Just today" : "Just \(day.formatted(.dateTime.weekday(.wide)))"
    }

    private func dropBar(_ p: PendingDrop) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(p.name).bold()) moves to \(Text(ScheduleEngine.clock(p.option.minutes)).bold())")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.dayText)
                    .monospacedDigit()
                if !p.option.alongside.isEmpty {
                    Text(p.option.alongside.map { "\($0.name) to \(ScheduleEngine.clock($0.minutes))" }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.daySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(justLabel) { commitDrop(p, scope: .today) }
                    .buttonStyle(CarryPrimaryButtonStyle())
                    .accessibilityIdentifier("drop-just-today")
                Button("Every day") { commitDrop(p, scope: .forward) }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.rose)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .background(Theme.roseTint, in: .capsule)
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("drop-every-day")
                Button("Undo") {
                    Haptics.tap()
                    pendingDrop = nil
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.daySecondary)
                .frame(minWidth: 56, minHeight: 50)
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("drop-undo")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.dayRadius, style: .continuous).stroke(Theme.dayDivider, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 16, y: -2)
        .padding(.horizontal, DayList.side)
        .padding(.bottom, 8)
    }

    private func commitDrop(_ p: PendingDrop, scope: ScheduleChange.Scope) {
        let old = store.dayState(owner, on: day)?.times ?? [:]
        store.applyMove(owner: owner, day: day, option: p.option, medicationID: p.id, scope: scope)
        Haptics.success()
        var marks = changed
        for id in [p.id] + p.option.alongside.map(\.id) {
            if let m = old[id] { marks[id] = marks[id] ?? m }
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            changed = marks
            pendingDrop = nil
        }
    }

    // MARK: Editor

    private func openEditor() {
        beforeTimes = store.dayState(owner, on: day)?.times ?? [:]
        beforeText = store.medsTextOrFallback(for: owner)
        showEditor = true
    }

    private func editorApplied() {
        showEditor = false
        let after = store.dayState(owner, on: day)?.times ?? [:]
        var marks: [UUID: Int] = [:]
        for (id, m) in after {
            if let old = beforeTimes[id], old != m { marks[id] = old }
        }
        undoText = beforeText
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            changed = marks
            let n = marks.count
            toast = "Plan updated · \(n) time\(n == 1 ? "" : "s") changed"
        }
    }

    private func undoEditorChange() {
        guard let old = undoText else { return }
        Haptics.tap()
        undoText = nil
        withAnimation { toast = nil; changed = [:] }
        store.saveMedsText(old, for: owner)
        Task { await store.reapplyTexts([owner]) }
    }
}
