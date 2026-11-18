import SwiftUI

/// Board 13 pushed from a month card: a round back button on the title row, then the month content.
struct TimelineMonthPage: View {
    var month: TimelineMonth
    var profile: PregnancyProfile
    var onEdit: (MilestoneEditorItem) -> Void
    var onDelete: (Milestone) -> Void
    var onWeek: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PaneScroll {
            TimelineMonthContent(month: month, profile: profile, onEdit: onEdit, onDelete: onDelete, onWeek: onWeek,
                                 onBack: { dismiss() })
        }
        .background(Theme.dayCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Header, week strip, size card, This month line of milestones, add button and the footnote.
/// Also the right pane on the open Duo.
struct TimelineMonthContent: View {
    @Environment(AppStore.self) private var store
    var month: TimelineMonth
    var profile: PregnancyProfile
    var onEdit: (MilestoneEditorItem) -> Void
    var onDelete: (Milestone) -> Void
    var onWeek: (Int) -> Void
    /// Pushed page only; the open Duo's right pane has no back.
    var onBack: (() -> Void)? = nil

    var body: some View {
        let age = profile.progress(on: store.now)
        header(age: age)
        weekStrip(age: age)
        sizeCard(age: age)
        thisMonth
        Button {
            Haptics.tap()
            onEdit(MilestoneEditorItem(milestone: nil, defaultDate: defaultDate))
        } label: {
            Label("Add a moment to Month \(month.number)", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BloomSoftButtonStyle(tint: Theme.rose, fill: Theme.roseTint))
        .accessibilityIdentifier("month-add")
        Text("Typical; your provider's schedule may differ.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.dayMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Header

    private func header(age: GestationalAge) -> some View {
        let span = Double((month.weeks.upperBound + 1 - month.startWeek) * 7)
        let progress = min(1, max(0, Double(age.totalDays - month.startWeek * 7) / span))
        return HStack(alignment: .top, spacing: 10) {
            if let onBack {
                RoundBackButton(identifier: "month-back", action: onBack)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Month \(month.number)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.dayText)
                    .frame(minHeight: ScreenHeader.row)
                    .accessibilityAddTraits(.isHeader)
                Text("\(month.weeksLabel) \u{00B7} \(month.datesLabel(profile))")
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(Theme.daySecondary)
            }
            Spacer(minLength: 8)
            CarryMark(size: 34, progress: max(progress, 0.001), trackColor: Theme.dayDivider)
                .padding(.top, 6)
        }
    }

    // MARK: Week strip

    private func weekStrip(age: GestationalAge) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(month.weeks), id: \.self) { week in
                let state: TimelineMonthState = week < age.weeks ? .past : (week == age.weeks ? .current : .future)
                Button {
                    Haptics.select()
                    onWeek(week)
                } label: {
                    VStack(spacing: 3) {
                        Text("Wk \(week)")
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                        Text(sub(week: week, state: state))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(state == .current ? .white : (state == .past ? Theme.greenText : Theme.daySecondary))
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background { chipBackground(state) }
                    .padding(state == .current ? 3 : 0)
                    .overlay {
                        if state == .current {
                            RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.rose, lineWidth: 1.5)
                        }
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("week-chip-\(week)")
            }
        }
    }

    private func sub(week: Int, state: TimelineMonthState) -> String {
        switch state {
        case .past: "done"
        case .current: "now"
        case .future: TimelineFormat.short(PregnancyMath.addDays(week * 7, to: profile.gestationStart))
        }
    }

    @ViewBuilder
    private func chipBackground(_ state: TimelineMonthState) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch state {
        case .past: shape.fill(Theme.greenTint)
        case .current: shape.fill(Theme.rose)
        case .future: shape.strokeBorder(Theme.dayMuted.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        }
    }

    // MARK: Size

    @ViewBuilder
    private func sizeCard(age: GestationalAge) -> some View {
        let week = month.weeks.contains(age.weeks) ? age.weeks : (age.weeks < month.weeks.lowerBound ? month.weeks.lowerBound : month.weeks.upperBound)
        if let content = WeekLibrary.week(week) {
            let next = WeekLibrary.week(week + 1)
            let length = content.lengthCm ?? 0
            let inner = 14 + 54 * CGFloat(min(1, sqrt(max(0, length) / 51)))
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.terraDot.opacity(0.45), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
                        .frame(width: 84, height: 84)
                    Circle()
                        .fill(Theme.terraTint)
                        .overlay(Circle().fill(Theme.terraDot).frame(width: inner * 0.28, height: inner * 0.28))
                        .frame(width: inner, height: inner)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.week <= 2 ? content.size.capitalizedFirst : "About the size of \(content.size)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.dayText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([content.measurementText, next.map { "next week \($0.size)" }].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.daySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Week \(content.week)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.terraText)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.dayCard, in: .rect(cornerRadius: 28, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("month-size-card")
        }
    }

    // MARK: This month

    private var items: [Milestone] {
        store.sortedMilestones.filter {
            TimelineMonth.number(forWeek: TimelineFormat.week(of: $0, profile)) == month.number
        }
    }

    private var defaultDate: Date {
        let start = month.start(profile), end = month.end(profile)
        let today = PregnancyMath.calendar.startOfDay(for: store.now)
        if today >= start && today <= end { return store.now }
        return PregnancyMath.calendar.date(byAdding: .hour, value: 12, to: start) ?? start
    }

    @ViewBuilder
    private var thisMonth: some View {
        let list = items
        let nextID = store.sortedMilestones.first { !$0.isPast(store.now) }?.id
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS MONTH")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.dayMuted)
                .padding(.leading, 4)
            if list.isEmpty {
                Text("A quiet month so far. Add a moment?")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(list) { milestone in
                        HStack(alignment: .center, spacing: 12) {
                            MilestoneNode(kind: kind(milestone, nextID: nextID), milestoneID: milestone.id)
                                .frame(width: 24)
                            MilestoneCard(milestone: milestone)
                                .swipeToDelete(onTap: { onEdit(MilestoneEditorItem(milestone: milestone)) },
                                               onDelete: { onDelete(milestone) })
                        }
                    }
                }
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.dayDivider)
                        .frame(width: 2)
                        .padding(.vertical, 24)
                        .padding(.leading, 11)
                }
            }
        }
    }

    private func kind(_ m: Milestone, nextID: UUID?) -> MilestoneNode.Kind {
        if m.isPast(store.now) { return .done }
        if m.id == nextID { return .next }
        if m.isSuggested && !m.userEdited { return .typical }
        return .upcoming
    }
}

// MARK: - Node

/// Green check when passed (the first time: fills, draws the check and bursts six dots, once),
/// rose with a ring for the next one, dashed for a typical one, a rose outline otherwise.
struct MilestoneNode: View {
    enum Kind { case done, next, typical, upcoming }
    var kind: Kind
    var milestoneID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = true
    @State private var check: CGFloat = 1
    @State private var burst = false
    @State private var celebrating = false

    var body: some View {
        ZStack {
            if celebrating {
                ForEach(0..<6, id: \.self) { i in
                    let a = Double(i) * .pi / 3
                    Circle()
                        .fill(i.isMultiple(of: 2) ? Theme.greenDot : Theme.rose)
                        .frame(width: 5, height: 5)
                        .offset(x: cos(a) * (burst ? 20 : 4), y: sin(a) * (burst ? 20 : 4))
                        .opacity(burst ? 0 : 1)
                }
            }
            node
        }
        .frame(width: 24, height: 24)
        .onAppear(perform: celebrateIfNeeded)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var node: some View {
        switch kind {
        case .done:
            ZStack {
                Circle().fill(filled ? Theme.greenCheck : Theme.dayCard)
                Circle().strokeBorder(filled ? Theme.greenCheck : Theme.rose, lineWidth: 2)
                CheckShape()
                    .trim(from: 0, to: check)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 9, height: 7)
            }
            .frame(width: 18, height: 18)
        case .next:
            Circle().fill(Theme.rose)
                .frame(width: 12, height: 12)
                .padding(3)
                .overlay(Circle().strokeBorder(Theme.rose.opacity(0.4), lineWidth: 2))
                .background(Circle().fill(Theme.dayCanvas))
        case .typical:
            Circle()
                .strokeBorder(Theme.dayMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                .background(Circle().fill(Theme.dayCanvas))
                .frame(width: 14, height: 14)
        case .upcoming:
            Circle().strokeBorder(Theme.rose, lineWidth: 2)
                .background(Circle().fill(Theme.dayCard))
                .frame(width: 14, height: 14)
        }
    }

    private func celebrateIfNeeded() {
        guard kind == .done, !CelebratedMilestones.contains(milestoneID) else { return }
        CelebratedMilestones.insert(milestoneID)
        filled = false
        check = 0
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4).delay(0.3)) {
                filled = true
                check = 1
            }
            return
        }
        celebrating = true
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.35)) { filled = true }
        withAnimation(.easeOut(duration: 0.35).delay(0.5)) { check = 1 }
        withAnimation(.easeOut(duration: 0.65).delay(0.45)) { burst = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Haptics.success() }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - Card

private struct MilestoneCard: View {
    var milestone: Milestone

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dateLine)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.rose)
                Text(milestone.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.daySecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let filename = milestone.photoFilename, let image = PhotoStore.image(filename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("milestone-\(milestone.title)")
    }

    private var dateLine: String {
        var text = milestone.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if milestone.hasTime { text += " \u{00B7} " + milestone.date.formatted(date: .omitted, time: .shortened) }
        return text
    }

    private var subtitle: String? {
        let notes = milestone.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { return notes }
        if milestone.isSuggested, !milestone.userEdited, let window = milestone.windowLabel { return "Typical \u{00B7} \(window)" }
        return milestone.isMarker ? nil : milestone.type.title
    }
}

// MARK: - Swipe to delete (outside a List)

extension View {
    func swipeToDelete(onTap: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(onTap: onTap, onDelete: onDelete))
    }
}

private struct SwipeToDelete: ViewModifier {
    var onTap: () -> Void
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var open = false
    private let reveal: CGFloat = 76

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                Haptics.tap()
                close()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: reveal - 8)
                    .frame(maxHeight: .infinity)
                    .background(Color.red, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
            }
            .opacity(offset < -6 ? 1 : 0)
            .accessibilityHidden(true)

            content
                .offset(x: offset)
                .contentShape(.rect)
                .onTapGesture {
                    if open { close() } else { Haptics.select(); onTap() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
                            offset = min(0, max(-reveal - 30, value.translation.width + (open ? -reveal : 0)))
                        }
                        .onEnded { _ in
                            withAnimation(.snappy(duration: 0.25)) {
                                open = offset < -reveal / 2
                                offset = open ? -reveal : 0
                            }
                        }
                )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Delete", onDelete)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) {
            open = false
            offset = 0
        }
    }
}
