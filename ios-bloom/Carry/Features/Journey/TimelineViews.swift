import SwiftUI

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
            Label("Add", systemImage: "plus.circle.fill")
        }
        .tint(Theme.blushDeep)
    }
}

/// Timeline tab: the month-by-month timeline with "You are here", milestones, scan photos and +.
struct TimelineTabView: View {
    @State private var editing: MilestoneEditorItem?

    var body: some View {
        NavigationStack {
            TimelineList(editing: $editing)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .duoListClearance()
                .background(CarryBackground())
                .navigationTitle("Timeline")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        TimelineAddMenu(editing: $editing)
                            .accessibilityIdentifier("timeline-add")
                    }
                }
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
                                    YouAreHereRow(headline: age.headline, emoji: WeekLibrary.week(age.contentWeek)?.emoji ?? "🌱")
                                        .listRowBackground(Theme.sageSoft)
                                }
                                if items.isEmpty && month.number != currentMonth {
                                    Text("A quiet month. Add a moment?")
                                        .font(.bloom(.subheadline))
                                        .foregroundStyle(Theme.textSecondary)
                                        .listRowBackground(Theme.surface)
                                }
                                ForEach(items) { milestone in
                                    Button { editing = MilestoneEditorItem(milestone: milestone) } label: {
                                        MilestoneRow(milestone: milestone, isPast: milestone.isPast(store.now))
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Theme.surface)
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
                .scrollContentBackground(.hidden)
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
                .font(.bloom(.title3, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(month.weeksLabel)
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if month.number == 1 || month.number == 4 || month.number == 7 {
                Text("Trimester \(month.trimester)")
                    .font(.bloom(.caption, weight: .bold))
                    .foregroundStyle(Theme.peachDeep)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.peachSoft, in: .capsule)
            }
        }
        .textCase(nil)
        .padding(.top, 6)
    }
}

private struct YouAreHereRow: View {
    var headline: String
    var emoji: String

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text("You are here")
                    .font(.bloom(.headline, weight: .heavy))
                    .foregroundStyle(Theme.sageDeep)
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
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 16, style: .continuous))
                } else {
                    Image(systemName: milestone.isMarker ? "sparkles" : milestone.type.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isPast ? Theme.sageDeep : milestone.type.tint)
                        .frame(width: 52, height: 52)
                        .background(isPast ? Theme.sageSoft : milestone.type.soft, in: .rect(cornerRadius: 16, style: .continuous))
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
                    .font(.bloom(.headline, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                if isPast {
                    Text(milestone.isMarker ? "Reached" : "Memory")
                        .font(.bloom(.caption, weight: .bold))
                        .foregroundStyle(Theme.sageDeep)
                } else if milestone.isSuggested && !milestone.userEdited {
                    Text("Suggested")
                        .font(.bloom(.caption, weight: .bold))
                        .foregroundStyle(Theme.peachDeep)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
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
