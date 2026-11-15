import SwiftUI

// MARK: - Horizontal strip on Journey

struct TimelineStrip: View {
    var milestones: [Milestone]
    var onSelect: (Milestone) -> Void
    var onAdd: () -> Void

    @Environment(AppStore.self) private var store

    private var firstUpcomingID: UUID? {
        milestones.first(where: { !$0.isPast(store.now) })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your timeline")
                        .font(.bloom(.title, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Typical; your provider's schedule may differ.")
                        .font(.bloom(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                NavigationLink(value: TimelineRoute()) {
                    Text("See all")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.blushDeep)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(milestones) { milestone in
                            Button { onSelect(milestone) } label: {
                                MilestoneChip(milestone: milestone, isPast: milestone.isPast(store.now))
                            }
                            .buttonStyle(PressableStyle())
                            .id(milestone.id)
                        }
                        Button(action: onAdd) {
                            Label("Add", systemImage: "plus")
                                .font(.bloom(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.blushDeep)
                                .padding(.horizontal, 18)
                                .frame(height: 58)
                                .background(Theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, -20)
                .onAppear {
                    guard let id = firstUpcomingID else { return }
                    // Show the most recent memory just before the next upcoming milestone.
                    if let index = milestones.firstIndex(where: { $0.id == id }), index > 0 {
                        proxy.scrollTo(milestones[index - 1].id, anchor: .leading)
                    }
                }
            }
        }
    }
}

struct MilestoneChip: View {
    var milestone: Milestone
    var isPast: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isPast {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.sageDeep)
                } else {
                    Image(systemName: milestone.isMarker ? "sparkles" : "calendar")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(milestone.title)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.bloom(.caption, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(Theme.surface, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var subtitle: String {
        if milestone.isSuggested, !milestone.userEdited, let window = milestone.windowLabel { return window }
        return milestone.date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Full 9-month timeline

private struct PregnancyMonth: Identifiable {
    let number: Int
    let weeks: ClosedRange<Int>
    var id: Int { number }

    var title: String { number == 10 ? "Overtime" : "Month \(number)" }
    var weeksLabel: String { "Wk \(weeks.lowerBound)–\(weeks.upperBound)" }
    var trimester: Int { number <= 3 ? 1 : (number <= 6 ? 2 : 3) }

    static let all: [PregnancyMonth] = [
        .init(number: 1, weeks: 1...4), .init(number: 2, weeks: 5...8), .init(number: 3, weeks: 9...13),
        .init(number: 4, weeks: 14...17), .init(number: 5, weeks: 18...22), .init(number: 6, weeks: 23...27),
        .init(number: 7, weeks: 28...31), .init(number: 8, weeks: 32...35), .init(number: 9, weeks: 36...40),
        .init(number: 10, weeks: 41...42),
    ]

    static func month(forWeek week: Int) -> Int {
        let clamped = min(max(week, 1), 42)
        return all.first { $0.weeks.contains(clamped) }?.number ?? 1
    }
}

/// Add / restore menu shared by the pushed timeline and the wide-layout pane.
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
        .tint(Theme.blushDeep)
    }
}

/// Pushed full-screen timeline (compact layouts).
struct FullTimelineView: View {
    @State private var editing: MilestoneEditorItem?

    var body: some View {
        TimelineList(editing: $editing)
            .background(BloomBackground())
            .navigationTitle("9-month timeline")
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TimelineAddMenu(editing: $editing)
                }
            }
    }
}

/// Right-hand pane of the wide (two-column) Journey layout.
struct TimelinePane: View {
    @State private var editing: MilestoneEditorItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your timeline")
                    .font(.bloom(.title2, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                TimelineAddMenu(editing: $editing)
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            TimelineList(editing: $editing)
        }
    }
}

/// The 9-month milestone list. Owns the delete dialog and the editor sheet.
struct TimelineList: View {
    @Environment(AppStore.self) private var store
    @Binding var editing: MilestoneEditorItem?
    @State private var pendingDelete: Milestone?

    var body: some View {
        if let profile = store.profile {
            let age = profile.progress(on: store.now)
            let currentMonth = PregnancyMonth.month(forWeek: age.weeks)
            ScrollViewReader { proxy in
                List {
                    ForEach(PregnancyMonth.all) { month in
                        let items = milestones(in: month, profile: profile)
                        if month.number < 10 || !items.isEmpty {
                            Section {
                                if month.number == currentMonth {
                                    YouAreHereRow(headline: age.headline)
                                }
                                if items.isEmpty && month.number != currentMonth {
                                    Text("A quiet month. Add a moment?")
                                        .font(.bloom(.subheadline))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                ForEach(items) { milestone in
                                    Button { editing = MilestoneEditorItem(milestone: milestone) } label: {
                                        MilestoneRow(milestone: milestone, isPast: milestone.isPast(store.now))
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            pendingDelete = milestone
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                MonthHeader(month: month, isCurrent: month.number == currentMonth)
                            }
                            .id(month.number)
                        }
                    }

                    Section {
                        Text("Typical; your provider's schedule may differ.")
                            .font(.bloom(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    proxy.scrollTo(currentMonth, anchor: .top)
                }
            }
            .sheet(item: $editing) { item in
                MilestoneEditorView(milestone: item.milestone)
            }
            .confirmationDialog(
                "Delete \"\(pendingDelete?.title ?? "")\"?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDelete { withAnimation { store.delete(pendingDelete) } }
                    pendingDelete = nil
                }
            }
        }
    }

    private func milestones(in month: PregnancyMonth, profile: PregnancyProfile) -> [Milestone] {
        store.sortedMilestones.filter { milestone in
            let days = PregnancyMath.days(from: profile.gestationStart, to: milestone.date)
            return PregnancyMonth.month(forWeek: days / 7) == month.number
        }
    }
}

private struct MonthHeader: View {
    var month: PregnancyMonth
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(month.title)
                .font(.bloom(.headline, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(month.weeksLabel)
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if month.number == 1 || month.number == 4 || month.number == 7 {
                Text("Trimester \(month.trimester)")
                    .font(.bloom(.caption, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .textCase(nil)
        .padding(.top, 6)
    }
}

private struct YouAreHereRow: View {
    var headline: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .font(.body)
                .foregroundStyle(Theme.blushDeep)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("You are here")
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.blushDeep)
                Text(headline)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MilestoneRow: View {
    var milestone: Milestone
    var isPast: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                if let filename = milestone.photoFilename, let image = PhotoStore.image(filename) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: milestone.isMarker ? "sparkles" : milestone.type.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(isPast ? Theme.sageDeep : Theme.blushDeep)
                        .frame(width: 40, height: 40)
                        .background(isPast ? Theme.sageSoft : Theme.surfaceMuted, in: .rect(cornerRadius: 8, style: .continuous))
                }
                if isPast {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Theme.sageDeep)
                        .offset(x: 5, y: 5)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(milestone.title)
                    .font(.bloom(.body, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                if isPast {
                    Text(milestone.isMarker ? "Reached" : "Memory")
                        .font(.bloom(.caption, weight: .medium))
                        .foregroundStyle(Theme.sageDeep)
                } else if milestone.isSuggested && !milestone.userEdited {
                    Text("Suggested")
                        .font(.bloom(.caption, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var detail: String {
        var text = milestone.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if milestone.hasTime { text += " · " + milestone.date.formatted(date: .omitted, time: .shortened) }
        if milestone.isSuggested, !milestone.userEdited, let window = milestone.windowLabel { text += " · \(window)" }
        return text
    }
}
