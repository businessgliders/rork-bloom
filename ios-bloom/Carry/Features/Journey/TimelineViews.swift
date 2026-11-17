import SwiftUI

// MARK: - Model

/// The nine months by week (month 1 also holds week 0; weeks 41–42 fold into month 9).
struct TimelineMonth: Identifiable, Hashable {
    let number: Int
    let weeks: ClosedRange<Int>
    var id: Int { number }

    var trimester: Int { number <= 3 ? 1 : (number <= 6 ? 2 : 3) }
    var startWeek: Int { number == 1 ? 0 : weeks.lowerBound }
    var weeksLabel: String { "Weeks \(weeks.lowerBound)\u{2013}\(weeks.upperBound)" }
    var shortWeeksLabel: String { "Wk \(weeks.lowerBound)\u{2013}\(weeks.upperBound)" }

    static let all: [TimelineMonth] = [
        .init(number: 1, weeks: 1...4), .init(number: 2, weeks: 5...8), .init(number: 3, weeks: 9...13),
        .init(number: 4, weeks: 14...17), .init(number: 5, weeks: 18...22), .init(number: 6, weeks: 23...27),
        .init(number: 7, weeks: 28...31), .init(number: 8, weeks: 32...35), .init(number: 9, weeks: 36...40),
    ]

    static func number(forWeek week: Int) -> Int {
        let clamped = min(max(week, 1), 40)
        return all.first { $0.weeks.contains(clamped) }?.number ?? 1
    }

    static func month(_ n: Int) -> TimelineMonth { all[min(max(n, 1), 9) - 1] }

    func start(_ profile: PregnancyProfile) -> Date {
        PregnancyMath.addDays(startWeek * 7, to: profile.gestationStart)
    }

    func end(_ profile: PregnancyProfile) -> Date {
        PregnancyMath.addDays((weeks.upperBound + 1) * 7 - 1, to: profile.gestationStart)
    }

    func datesLabel(_ profile: PregnancyProfile) -> String {
        "\(TimelineFormat.short(start(profile)))\u{2009}\u{2013}\u{2009}\(TimelineFormat.short(end(profile)))"
    }
}

struct TimelineTrimester: Identifiable {
    let number: Int
    let months: [Int]
    /// Arc span in weeks: [startWeek, endWeek).
    let startWeek: Int
    let endWeek: Int
    let weeksLabel: String
    let name: String
    let note: String
    var id: Int { number }

    static let all: [TimelineTrimester] = [
        .init(number: 1, months: [1, 2, 3], startWeek: 0, endWeek: 14, weeksLabel: "Weeks 1\u{2013}13",
              name: "First trimester", note: "Most of Baby's organs form now; tiredness and nausea often peak around week 9."),
        .init(number: 2, months: [4, 5, 6], startWeek: 14, endWeek: 28, weeksLabel: "Weeks 14\u{2013}27",
              name: "Second trimester", note: "Often the easiest stretch. First kicks usually arrive between weeks 18 and 22."),
        .init(number: 3, months: [7, 8, 9], startWeek: 28, endWeek: 40, weeksLabel: "Weeks 28\u{2013}40",
              name: "Third trimester", note: "Baby puts on most of their weight. A packed bag by week 36 keeps things calm."),
    ]

    func start(_ profile: PregnancyProfile) -> Date { PregnancyMath.addDays(startWeek * 7, to: profile.gestationStart) }
    func end(_ profile: PregnancyProfile) -> Date {
        number == 3 ? profile.dueDate : PregnancyMath.addDays(endWeek * 7 - 1, to: profile.gestationStart)
    }

    func progress(_ age: GestationalAge) -> Double {
        let span = Double((endWeek - startWeek) * 7)
        return min(1, max(0, Double(age.totalDays - startWeek * 7) / span))
    }
}

enum TimelineFormat {
    static func short(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func week(of milestone: Milestone, _ profile: PregnancyProfile) -> Int {
        PregnancyMath.days(from: profile.gestationStart, to: milestone.date) / 7
    }

    static func relative(_ date: Date, now: Date) -> String {
        let days = PregnancyMath.days(from: now, to: date)
        switch days {
        case ..<0: return "Passed"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "In \(days) days"
        }
    }

    static func monthState(_ month: TimelineMonth, age: GestationalAge) -> TimelineMonthState {
        let current = TimelineMonth.number(forWeek: age.weeks)
        if month.number == current { return .current }
        return month.number < current ? .past : .future
    }

    static let pastBeige = Color(light: 0xD8C7B6, dark: 0x5C4C45)
}

enum TimelineMonthState { case past, current, future }

/// Milestones whose "reached" moment already played (node fills green, check, burst), once each.
enum CelebratedMilestones {
    private static let key = "carry.timeline.celebrated"

    static func contains(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static func insert(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// First run: everything already past counts as seen, so only milestones passing from now on celebrate.
    static func seedIfNeeded(_ milestones: [Milestone]) {
        guard UserDefaults.standard.stringArray(forKey: key) == nil else { return }
        UserDefaults.standard.set(milestones.map(\.id.uuidString), forKey: key)
    }
}

// MARK: - Tab

/// Add / restore menu on the Timeline tab.
private struct TimelineAddMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var editing: MilestoneEditorItem?

    var body: some View {
        Menu {
            Button {
                editing = MilestoneEditorItem(milestone: nil)
            } label: {
                Label("Add milestone", systemImage: "plus")
            }
            Button {
                store.restoreSuggestions()
                Haptics.success()
            } label: {
                Label("Restore typical milestones", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .tint(Theme.rose)
    }
}

/// Timeline (boards 12–15): the pregnancy arc, a pager of trimester cards with month tiles and Coming up.
/// A month tile opens the month view (zoom on iOS 18). Open Duo: overview left, the selected month right.
struct TimelineTabView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [Int] = []
    @State private var editing: MilestoneEditorItem?
    @State private var pendingDelete: Milestone?
    @State private var weekSheet: WeekSheetItem?
    @State private var page: Int?
    @State private var selectedMonth: Int?
    @State private var appeared = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let profile = store.profile {
                    content(profile)
                }
            }
            .navigationTitle("Timeline")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TimelineAddMenu(editing: $editing)
                        .accessibilityIdentifier("timeline-add")
                }
            }
            .navigationDestination(for: Int.self) { number in
                if let profile = store.profile {
                    TimelineMonthPage(
                        month: TimelineMonth.month(number),
                        profile: profile,
                        onEdit: { editing = $0 },
                        onDelete: { pendingDelete = $0 },
                        onWeek: { weekSheet = WeekSheetItem(week: $0) }
                    )
                    .timelineZoomDestination(number, in: zoom)
                }
            }
        }
        .sheet(item: $editing) { item in
            MilestoneEditorView(milestone: item.milestone, defaultDate: item.defaultDate)
        }
        .sheet(item: $weekSheet) { item in
            if let profile = store.profile { WeekDetailSheet(week: item.week, profile: profile) }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { withAnimation { store.delete(pendingDelete) } }
                Haptics.warning()
                pendingDelete = nil
            }
        }
        .onAppear {
            CelebratedMilestones.seedIfNeeded(store.sortedMilestones.filter { $0.isPast(store.now) })
        }
    }

    @ViewBuilder
    private func content(_ profile: PregnancyProfile) -> some View {
        let age = profile.progress(on: store.now)
        let current = TimelineMonth.number(forWeek: age.weeks)
        AdaptiveColumns {
            PaneScroll(pane: .primary) {
                overview(profile, age: age, highlight: selectedMonth ?? current) { n in
                    Haptics.select()
                    withAnimation(.snappy) { selectedMonth = n }
                }
            }
            .accessibilityIdentifier("timeline-overview-pane")
        } secondary: {
            PaneScroll(pane: .secondary) {
                TimelineMonthContent(
                    month: TimelineMonth.month(selectedMonth ?? current),
                    profile: profile,
                    onEdit: { editing = $0 },
                    onDelete: { pendingDelete = $0 },
                    onWeek: { weekSheet = WeekSheetItem(week: $0) }
                )
                .id(selectedMonth ?? current)
                .transition(.opacity)
            }
            .accessibilityIdentifier("timeline-month-pane")
        } compact: {
            PaneScroll {
                overview(profile, age: age, highlight: current) { n in
                    Haptics.select()
                    path.append(n)
                }
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
        }
        .background(Theme.dayCanvas.ignoresSafeArea())
        .onAppear {
            if page == nil { page = age.trimester }
            appeared = true
        }
    }

    @ViewBuilder
    private func overview(_ profile: PregnancyProfile, age: GestationalAge, highlight: Int,
                          open: @escaping (Int) -> Void) -> some View {
        Text("\(age.daysToGoText) \u{00B7} due \(profile.dueDate.formatted(.dateTime.month(.abbreviated).day().year()))")
            .font(.system(size: 15, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.daySecondary)
            .padding(.top, -6)
            .accessibilityIdentifier("timeline-subtitle")

        PregnancyArcHero(age: age, content: WeekLibrary.week(age.contentWeek), selectedTrimester: page ?? age.trimester)
            .frame(maxWidth: .infinity)

        TrimesterPager(profile: profile, age: age, page: $page, highlightMonth: highlight,
                       appeared: appeared, zoom: zoom, onOpenMonth: open)

        ComingUpSection(profile: profile) { editing = MilestoneEditorItem(milestone: $0) }
            .timelineRise(index: 3, appeared: appeared)
    }
}

// MARK: - Zoom transition (iOS 18; a plain push on iOS 17)

extension View {
    @ViewBuilder
    func timelineZoomSource(_ id: Int, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func timelineZoomDestination(_ id: Int, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    /// Fade and rise in with a 60 ms stagger; a plain fade with Reduce Motion.
    func timelineRise(index: Int, appeared: Bool) -> some View {
        modifier(TimelineRise(index: index, appeared: appeared))
    }
}

private struct TimelineRise: ViewModifier {
    var index: Int
    var appeared: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(.easeOut(duration: 0.45).delay(0.06 * Double(index)), value: appeared)
    }
}

// MARK: - Arc hero

/// The CarryMark arc for the whole pregnancy: counter-clockwise from week 0 (top tip) to week 40
/// (bottom tip), in three trimester segments; rose up to today, a terracotta dot on today.
struct PregnancyArcHero: View {
    var age: GestationalAge
    var content: WeekContent?
    var selectedTrimester: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: Double = 0
    @State private var dotIn = false
    @State private var started = false

    static let diameter: CGFloat = 236
    static let lineWidth: CGFloat = 22
    static let pad: CGFloat = 26

    private var target: Double { min(40, Double(age.totalDays) / 7) }

    var body: some View {
        let side = Self.diameter + Self.pad * 2
        let r = Self.diameter / 2 - Self.lineWidth / 2
        let theta = PregnancyArcLayer.angle(target) * .pi / 180
        ZStack {
            PregnancyArcLayer(fill: fill, selected: selectedTrimester, days: age.days, sizeLine: sizeLine)
            TodayDot(pulsing: dotIn && !reduceMotion)
                .scaleEffect(dotIn ? 1 : 0.01)
                .opacity(dotIn ? 1 : 0)
                .offset(x: r * cos(theta), y: r * sin(theta))
        }
        .frame(width: side, height: side)
        .onAppear(perform: start)
        .onChange(of: age.totalDays) { _, _ in fill = target }
        .accessibilityElement()
        .accessibilityLabel("Week \(age.weeks), \(age.days) days. \(age.trimesterTitle). \(sizeLine)")
        .accessibilityIdentifier("timeline-arc")
    }

    private var sizeLine: String {
        guard let content, content.week >= 3 else { return "" }
        var text = "about \(content.size)"
        if let cm = content.lengthCm {
            text += cm < 1 ? " \u{00B7} \(Int((cm * 10).rounded())) mm"
                : " \u{00B7} \(cm.formatted(.number.precision(.fractionLength(0...1)))) cm"
        }
        return text
    }

    private func start() {
        guard !started else { fill = target; return }
        started = true
        if reduceMotion {
            fill = target
            withAnimation(.easeOut(duration: 0.3)) { dotIn = true }
            return
        }
        fill = 0
        withAnimation(.easeInOut(duration: 1.3)) { fill = target }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(1.2)) { dotIn = true }
    }
}

/// Redrawn every frame while `fill` animates, so the arc and the counting week stay in step.
private struct PregnancyArcLayer: View, Animatable {
    var fill: Double
    var selected: Int
    var days: Int
    var sizeLine: String

    var animatableData: Double {
        get { fill }
        set { fill = newValue }
    }

    /// Degrees in screen space: week 0 at 315 (top tip), week 40 at 45 (bottom tip).
    static func angle(_ week: Double) -> Double { 315 - week / 40 * 270 }

    private static let segments: [(Int, ClosedRange<Double>)] = [(1, 0...14), (2, 14...28), (3, 28...40)]

    var body: some View {
        let week = Int(fill.rounded(.down))
        ZStack {
            Canvas { ctx, size in draw(ctx, size: size) }
            VStack(spacing: 2) {
                Text("\(week)")
                    .font(.system(size: 58, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dayText)
                Text(days == 0 ? (week == 1 ? "week" : "weeks") : "weeks, \(days) \(days == 1 ? "day" : "days")")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.daySecondary)
                if !sizeLine.isEmpty {
                    Text(sizeLine)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.terraText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 4)
                }
            }
            .frame(width: PregnancyArcHero.diameter * 0.62)
            .offset(x: -8)
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let lw = PregnancyArcHero.lineWidth
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = PregnancyArcHero.diameter / 2 - lw / 2
        let insetWeeks = ((lw / 2 + 3) / r) * 180 / .pi / 270 * 40
        let style = StrokeStyle(lineWidth: lw, lineCap: .round)

        func arc(_ a: Double, _ b: Double) -> Path {
            var p = Path()
            p.addArc(center: c, radius: r, startAngle: .degrees(Self.angle(a)), endAngle: .degrees(Self.angle(b)), clockwise: true)
            return p
        }

        for (i, seg) in Self.segments.enumerated() {
            let lo = seg.1.lowerBound + (i > 0 ? insetWeeks : 0)
            let hi = seg.1.upperBound - (i < 2 ? insetWeeks : 0)
            let isSelected = seg.0 == selected
            ctx.stroke(arc(lo, hi), with: .color(isSelected ? Theme.roseTint : Theme.dayDivider), style: style)
            let end = min(fill, hi)
            if end > lo + 0.01 {
                ctx.stroke(arc(lo, end), with: .color(Theme.rose.opacity(isSelected ? 1 : 0.72)), style: style)
            }
            // T1 / T2 / T3 outside each segment.
            let mid = Self.angle((seg.1.lowerBound + seg.1.upperBound) / 2) * .pi / 180
            let lr = r + lw / 2 + 14
            ctx.draw(
                Text("T\(seg.0)").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? Theme.rose : Theme.dayMuted),
                at: CGPoint(x: c.x + lr * cos(mid), y: c.y + lr * sin(mid))
            )
        }
    }
}

private struct TodayDot: View {
    var pulsing: Bool

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .stroke(Theme.terraDot.opacity(0.5), lineWidth: 2)
                    .frame(width: 20, height: 20)
                    .phaseAnimator([false, true]) { ring, out in
                        ring.scaleEffect(out ? 1.9 : 1).opacity(out ? 0 : 1)
                    } animation: { out in out ? .easeOut(duration: 1.6) : .linear(duration: 0.01) }
            }
            Circle()
                .fill(Theme.terraDot)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3.5))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Trimester pager

private struct TrimesterPager: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var profile: PregnancyProfile
    var age: GestationalAge
    @Binding var page: Int?
    var highlightMonth: Int
    var appeared: Bool
    var zoom: Namespace.ID
    var onOpenMonth: (Int) -> Void

    var body: some View {
        let counts = milestoneCounts
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(TimelineTrimester.all.enumerated()), id: \.element.id) { index, trimester in
                        TrimesterCard(trimester: trimester, profile: profile, age: age, counts: counts,
                                      highlightMonth: highlightMonth, zoom: zoom, onOpenMonth: onOpenMonth)
                            .frame(width: 300)
                            .scrollTransition(.interactive, axis: .horizontal) { card, phase in
                                card
                                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.92)
                                    .opacity(phase.isIdentity ? 1 : 0.55)
                            }
                            .timelineRise(index: index + 1, appeared: appeared)
                            .id(trimester.number)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)
            .padding(.horizontal, -20)
            .onChange(of: page) { _, _ in Haptics.select() }
            .accessibilityIdentifier("timeline-trimester-pager")

            HStack(spacing: 7) {
                ForEach(TimelineTrimester.all) { t in
                    Circle()
                        .fill(t.number == (page ?? age.trimester) ? Theme.rose : Theme.dayDivider)
                        .frame(width: 7, height: 7)
                }
            }
            .animation(.snappy, value: page)
            .accessibilityHidden(true)
        }
        .animation(.easeInOut(duration: 0.3), value: page)
    }

    private var milestoneCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for m in store.sortedMilestones {
            counts[TimelineMonth.number(forWeek: TimelineFormat.week(of: m, profile)), default: 0] += 1
        }
        return counts
    }
}

private struct TrimesterCard: View {
    var trimester: TimelineTrimester
    var profile: PregnancyProfile
    var age: GestationalAge
    var counts: [Int: Int]
    var highlightMonth: Int
    var zoom: Namespace.ID
    var onOpenMonth: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRIMESTER \(trimester.number)")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.rose)
                Text(trimester.weeksLabel)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.dayText)
                Text("\(trimester.name) \u{00B7} \(TimelineFormat.short(trimester.start(profile)))\u{2009}\u{2013}\u{2009}\(TimelineFormat.short(trimester.end(profile)))")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.daySecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.dayDivider)
                    Capsule().fill(Theme.rose).frame(width: geo.size.width * trimester.progress(age))
                }
            }
            .frame(height: 4)
            .accessibilityLabel("\(Int(trimester.progress(age) * 100)) percent through")

            HStack(spacing: 8) {
                ForEach(trimester.months, id: \.self) { n in
                    MonthTile(month: TimelineMonth.month(n), state: TimelineFormat.monthState(TimelineMonth.month(n), age: age),
                              count: counts[n] ?? 0, highlighted: n == highlightMonth) {
                        onOpenMonth(n)
                    }
                    .timelineZoomSource(n, in: zoom)
                }
            }

            Text(trimester.note)
                .font(.system(size: 13))
                .foregroundStyle(Theme.daySecondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Theme.dayCard, in: .rect(cornerRadius: 28, style: .continuous))
        .accessibilityIdentifier("trimester-card-\(trimester.number)")
    }
}

private struct MonthTile: View {
    var month: TimelineMonth
    var state: TimelineMonthState
    var count: Int
    var highlighted: Bool
    var action: () -> Void

    private var diameter: CGFloat { 6 + CGFloat(month.number - 1) * 34 / 8 }
    private var color: Color {
        switch state {
        case .current: Theme.rose
        case .past: TimelineFormat.pastBeige
        case .future: Theme.dayDivider
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
                    .frame(width: 42, height: 42)
                Text("Month \(month.number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
                Text(month.shortWeeksLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dayMuted)
                HStack(spacing: 3) {
                    ForEach(0..<min(count, 4), id: \.self) { _ in
                        Circle().fill(Theme.rose).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(highlighted ? Theme.roseTint : Theme.creamBox, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.rose, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Month \(month.number), weeks \(month.weeks.lowerBound) to \(month.weeks.upperBound), \(count) \(count == 1 ? "milestone" : "milestones")")
        .accessibilityIdentifier("month-tile-\(month.number)")
    }
}

// MARK: - Coming up

private struct ComingUpSection: View {
    @Environment(AppStore.self) private var store
    var profile: PregnancyProfile
    var onEdit: (Milestone) -> Void

    var body: some View {
        let next = Array(store.sortedMilestones.filter { !$0.isPast(store.now) }.prefix(2))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("COMING UP")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.dayMuted)
                    .padding(.leading, 4)
                DayCard {
                    ForEach(Array(next.enumerated()), id: \.element.id) { index, milestone in
                        if index > 0 { DayDivider() }
                        DayRow(
                            time: TimelineFormat.short(milestone.date),
                            dot: Theme.rose,
                            name: milestone.title,
                            nameAction: { onEdit(milestone) },
                            identifier: "coming-\(milestone.title)",
                            timeNote: TimelineFormat.relative(milestone.date, now: store.now)
                        ) {
                            Button { onEdit(milestone) } label: {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.dayMuted)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Edit \(milestone.title)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("timeline-coming-up")
        }
    }
}
