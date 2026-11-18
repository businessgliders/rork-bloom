import SwiftUI

// MARK: - Trimester bar

/// Three segments under the arc: done trimesters rose, the current one rose up to today, the rest beige.
/// The selected trimester's label is rose; tapping a label jumps the carousel to its first month.
struct TrimesterBar: View {
    var age: GestationalAge
    var selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(TimelineTrimester.all) { t in
                let isSelected = t.number == selected
                Button {
                    onSelect(t.number)
                } label: {
                    VStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.dayDivider)
                                Capsule().fill(Theme.rose)
                                    .frame(width: geo.size.width * t.progress(age))
                            }
                        }
                        .frame(height: isSelected ? 8 : 6)
                        .frame(height: 8)
                        Text("T\(t.number) \u{00B7} \(t.weeksLabel.replacingOccurrences(of: "Weeks ", with: "Wk "))")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Theme.rose : Theme.dayMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(PressableStyle())
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(t.name), \(Int(t.progress(age) * 100)) percent through")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("trimester-label-\(t.number)")
            }
        }
        .animation(.snappy, value: selected)
        .accessibilityIdentifier("trimester-bar")
    }
}

// MARK: - Month carousel

/// Months 1–9 (10 when a milestone falls in it or the pregnancy runs past week 40), one ~290 pt card
/// centred at a time; neighbours shrink and fade. Snaps per card, with page dots below.
struct MonthCarousel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var profile: PregnancyProfile
    var age: GestationalAge
    @Binding var page: Int?
    var zoom: Namespace.ID
    var onOpenMonth: (Int) -> Void

    static let cardWidth: CGFloat = 290
    @State private var width: CGFloat = 390

    var body: some View {
        let byMonth = milestonesByMonth
        let months = TimelineMonth.all.filter { $0.number <= 9 || age.weeks >= 41 || !(byMonth[$0.number] ?? []).isEmpty }
        let current = TimelineMonth.number(forWeek: age.weeks)
        let side = max(16, (width - Self.cardWidth) / 2)
        let shrink = !reduceMotion
        VStack(spacing: 14) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(months) { month in
                        MonthCard(month: month, profile: profile, age: age, current: current,
                                  milestones: byMonth[month.number] ?? []) {
                            onOpenMonth(month.number)
                        }
                        .frame(width: Self.cardWidth)
                        .frame(maxHeight: .infinity)
                        .timelineZoomSource(month.number, in: zoom)
                        .scrollTransition(.interactive, axis: .horizontal) { card, phase in
                            card
                                .scaleEffect(phase.isIdentity || !shrink ? 1 : 0.92)
                                .opacity(phase.isIdentity ? 1 : 0.45)
                        }
                        .id(month.number)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .safeAreaPadding(.horizontal, side)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $page)
            .scrollClipDisabled()
            // Measured inside the bleed: the scroll view itself spans the full screen width.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, -20)
            .onChange(of: page) { old, new in
                if old != nil, new != nil { Haptics.select() }
            }
            // A page set before the first layout (e.g. the Duo split) isn't applied by scrollPosition alone.
            .task(id: width) {
                try? await Task.sleep(for: .milliseconds(30))
                proxy.scrollTo(page ?? current, anchor: .center)
            }
            .accessibilityIdentifier("timeline-month-carousel")
            }

            HStack(spacing: 6) {
                ForEach(months) { month in
                    let on = month.number == (page ?? current)
                    Capsule()
                        .fill(on ? Theme.rose : Theme.dayDivider)
                        .frame(width: on ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: page)
            .accessibilityElement()
            .accessibilityLabel("Month \(page ?? current) of \(months.count)")
            .accessibilityIdentifier("timeline-month-dots")
        }
    }

    private var milestonesByMonth: [Int: [Milestone]] {
        var map: [Int: [Milestone]] = [:]
        for m in store.sortedMilestones {
            map[TimelineMonth.number(forWeek: TimelineFormat.week(of: m, profile)), default: []].append(m)
        }
        return map
    }
}

// MARK: - Month card

struct MonthCard: View {
    @Environment(AppStore.self) private var store
    var month: TimelineMonth
    var profile: PregnancyProfile
    var age: GestationalAge
    var current: Int
    var milestones: [Milestone]
    var action: () -> Void

    private var state: TimelineMonthState {
        month.number == current ? .current : (month.number < current ? .past : .future)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("TRIMESTER \(month.trimester)")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.rose)
                    Spacer(minLength: 6)
                    tag
                }

                HStack(spacing: 14) {
                    orb
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Month \(month.number)")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.dayText)
                        Text("\(month.weeksLabel) \u{00B7} \(month.datesLabel(profile))")
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(Theme.daySecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let size = sizeLine {
                            Text(size)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.terraText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }

                milestoneRows

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Text("Open month")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.rose)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.dayCard, in: .rect(cornerRadius: 28, style: .continuous))
            .overlay {
                if state == .current {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.rose, lineWidth: 2)
                }
            }
            .contentShape(.rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the month")
        .accessibilityIdentifier("month-card-\(month.number)")
    }

    // MARK: Pieces

    @ViewBuilder
    private var tag: some View {
        let (text, fg, bg): (String, Color, Color) = switch state {
        case .current: ("Now \u{00B7} week \(age.weeks)", Theme.rose, Theme.roseTint)
        case .past: ("Done", Theme.greenText, Theme.greenTint)
        case .future: ("Starts \(TimelineFormat.short(month.start(profile)))", Theme.daySecondary, Theme.creamBox)
        }
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(bg, in: .capsule)
    }

    /// The size orb grows month by month inside a 64 pt circle.
    private var orb: some View {
        let d = 12 + CGFloat(month.number - 1) * 38 / 9
        let color: Color = switch state {
        case .current: Theme.rose
        case .past: TimelineFormat.pastBeige
        case .future: Theme.dayDivider
        }
        return Circle()
            .fill(state == .current ? Theme.roseTint : Theme.creamBox)
            .frame(width: 64, height: 64)
            .overlay(Circle().fill(color).frame(width: d, height: d))
            .accessibilityHidden(true)
    }

    /// "a sweet pea · 6 mm" now and before; "a lime by the end" ahead.
    private var sizeLine: String? {
        let week: Int
        switch state {
        case .current: week = max(age.contentWeek, 1)
        case .past, .future: week = min(month.weeks.upperBound, 40)
        }
        guard let content = WeekLibrary.week(week), content.week >= 3 else { return nil }
        if state == .future { return "\(content.size) by the end" }
        if let cm = content.lengthCm { return "\(content.size) \u{00B7} \(TimelineFormat.length(cm))" }
        return content.size
    }

    @ViewBuilder
    private var milestoneRows: some View {
        if milestones.isEmpty {
            Text("A quiet month so far")
                .font(.system(size: 14))
                .foregroundStyle(Theme.dayMuted)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(milestones.prefix(3)) { m in
                    let typical = m.isSuggested && !m.userEdited && !m.isPast(store.now)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(m.isPast(store.now) ? Theme.greenDot : (typical ? Theme.neutralDot : Theme.rose))
                            .frame(width: 8, height: 8)
                        Text(m.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.dayText)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(typical ? "Typical" : TimelineFormat.short(m.date))
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dayMuted)
                    }
                }
                if milestones.count > 3 {
                    Text("+\(milestones.count - 3) more")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.daySecondary)
                        .padding(.leading, 18)
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = ["Month \(month.number)", "trimester \(month.trimester)", month.weeksLabel]
        switch state {
        case .current: parts.append("now, week \(age.weeks)")
        case .past: parts.append("done")
        case .future: parts.append("starts \(TimelineFormat.short(month.start(profile)))")
        }
        if let sizeLine { parts.append(sizeLine) }
        parts.append("\(milestones.count) \(milestones.count == 1 ? "milestone" : "milestones")")
        return parts.joined(separator: ", ")
    }
}
