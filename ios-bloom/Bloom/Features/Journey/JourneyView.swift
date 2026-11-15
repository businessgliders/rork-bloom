import SwiftUI

struct JourneyView: View {
    @Environment(AppStore.self) private var store

    /// Week being previewed with the chevrons; nil = today.
    @State private var browseWeek: Int?
    @State private var showDates = false
    @State private var showSettings = false
    @State private var detailWeek: WeekSheetItem?
    @State private var editingMilestone: MilestoneEditorItem?

    var body: some View {
        NavigationStack {
            if let profile = store.profile {
                let age = profile.progress(on: store.now)
                let weekNumber = browseWeek ?? age.contentWeek
                AdaptiveColumns {
                    // Wide, left pane: progress ring + This week.
                    List {
                        weekSections(profile: profile, age: age, weekNumber: weekNumber)
                    }
                    .listStyle(.insetGrouped)
                    .duoListClearance()
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(Theme.canvas)
                } secondary: {
                    // Wide, right pane: the full timeline.
                    TimelinePane()
                } compact: {
                    // Regular iPhones, Duo outer display, tall inner display.
                    List {
                        weekSections(profile: profile, age: age, weekNumber: weekNumber)
                        timelineSection
                    }
                    .listStyle(.insetGrouped)
                    .duoListClearance()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .background(Theme.canvas)
                }
                .navigationTitle(browseWeek.map { "Week \($0)" } ?? age.headline)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tint(Theme.blushDeep)
                    }
                }
                .navigationDestination(for: TimelineRoute.self) { _ in
                    FullTimelineView()
                }
                .sheet(isPresented: $showDates) {
                    NavigationStack { EditDatesView() }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .sheet(item: $detailWeek) { item in
                    WeekDetailSheet(week: item.week, profile: profile)
                }
                .sheet(item: $editingMilestone) { item in
                    MilestoneEditorView(milestone: item.milestone)
                }
            }
        }
    }

    @ViewBuilder
    private func weekSections(profile: PregnancyProfile, age: GestationalAge, weekNumber: Int) -> some View {
        Section {
            WeekHeroView(
                profile: profile,
                age: age,
                browseWeek: $browseWeek,
                onOpenWeek: { detailWeek = WeekSheetItem(week: weekNumber) }
            )
        }

        Section {
            if browseWeek == nil {
                Button { showDates = true } label: {
                    LabeledContent {
                        Text(age.daysToGoText)
                            .foregroundStyle(Theme.textSecondary)
                    } label: {
                        Text("Due \(profile.dueDate.formatted(.dateTime.month(.wide).day().year()))")
                            .foregroundStyle(Theme.text)
                    }
                }
                .accessibilityHint("Edit due date")
            } else {
                Button {
                    Haptics.select()
                    withAnimation(.snappy) { browseWeek = nil }
                } label: {
                    Label("Back to this week", systemImage: "arrow.uturn.backward")
                        .foregroundStyle(Theme.blushDeep)
                }
            }
        }

        if let content = WeekLibrary.week(weekNumber) {
            ThisWeekSection(content: content, profile: profile, isCurrent: browseWeek == nil) {
                detailWeek = WeekSheetItem(week: weekNumber)
            }
        }
    }

    /// The next few milestones as plain rows, with a link to the full timeline.
    @ViewBuilder
    private var timelineSection: some View {
        let upcoming = Array(store.sortedMilestones.filter { !$0.isPast(store.now) }.prefix(3))
        Section {
            ForEach(upcoming) { milestone in
                Button { editingMilestone = MilestoneEditorItem(milestone: milestone) } label: {
                    MilestoneRow(milestone: milestone, isPast: false)
                }
                .buttonStyle(.plain)
            }
            NavigationLink(value: TimelineRoute()) {
                Text("See full timeline")
                    .foregroundStyle(Theme.blushDeep)
            }
            Button {
                editingMilestone = MilestoneEditorItem(milestone: nil)
            } label: {
                Label("Add a milestone", systemImage: "plus")
                    .foregroundStyle(Theme.blushDeep)
            }
        } header: {
            Text("Coming up")
        } footer: {
            Text("Typical; your provider's schedule may differ.")
        }
    }
}

struct TimelineRoute: Hashable {}

struct WeekSheetItem: Identifiable {
    let week: Int
    var id: Int { week }
}

struct MilestoneEditorItem: Identifiable {
    let id = UUID()
    let milestone: Milestone?
}

// MARK: - Hero

/// Week browser, progress ring and the size comparison as text.
struct WeekHeroView: View {
    var profile: PregnancyProfile
    var age: GestationalAge
    @Binding var browseWeek: Int?
    var onOpenWeek: () -> Void

    private var shownWeek: Int { browseWeek ?? age.contentWeek }
    private var content: WeekContent? { WeekLibrary.week(shownWeek) }
    private var progress: Double {
        browseWeek == nil ? age.ringProgress : Double(shownWeek * 7) / 280
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                chevron("chevron.left", enabled: shownWeek > 1) { shift(-1) }
                Spacer()
                Text(caption)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                Spacer()
                chevron("chevron.right", enabled: shownWeek < 42) { shift(1) }
            }

            Button(action: onOpenWeek) {
                VStack(spacing: 16) {
                    ZStack {
                        ProgressRing(progress: progress, lineWidth: 12)
                        VStack(spacing: 0) {
                            Text("\(shownWeek)")
                                .font(.system(.largeTitle, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(shownWeek == 1 ? "week" : "weeks")
                                .font(.bloom(.subheadline))
                                .foregroundStyle(Theme.textSecondary)
                            Text("\(Int((min(progress, 1) * 100).rounded()))%")
                                .font(.bloom(.caption, weight: .semibold))
                                .foregroundStyle(Theme.blushDeep)
                                .monospacedDigit()
                                .padding(.top, 4)
                        }
                    }
                    .frame(width: 168, height: 168)

                    VStack(spacing: 4) {
                        Text(content?.sizeLabel ?? "Growing")
                            .font(.bloom(.headline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center)
                        if let measurement = content?.measurementText {
                            Text(measurement)
                                .font(.bloom(.subheadline))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Week \(shownWeek). \(content?.sizeLabel ?? ""). \(content?.measurementText ?? "")")
            .accessibilityHint("Opens this week's details")
        }
        .padding(.vertical, 8)
        .animation(.snappy, value: shownWeek)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    shift(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var caption: String {
        if browseWeek == nil {
            return "\(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · \(age.trimesterTitle)"
        }
        let start = PregnancyMath.addDays(shownWeek * 7, to: profile.gestationStart)
        return "Week of \(start.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Theme.blushDeep : Color(uiColor: .tertiaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous week" : "Next week")
    }

    private func shift(_ delta: Int) {
        let target = min(max(shownWeek + delta, 1), 42)
        guard target != shownWeek else { return }
        Haptics.select()
        withAnimation(.snappy) {
            browseWeek = target == age.contentWeek ? nil : target
        }
    }
}

// MARK: - This week

struct ThisWeekSection: View {
    var content: WeekContent
    var profile: PregnancyProfile
    var isCurrent: Bool
    var onMore: () -> Void

    var body: some View {
        Section {
            row(symbol: "figure.child", title: profile.babyName,
                text: content.babyText(name: profile.babyName))
            row(symbol: "person", title: profile.momName,
                text: content.momText(name: profile.momName))
            row(symbol: "person.2",
                title: profile.hasPartner ? profile.partnerName : "Partner",
                text: content.partnerText(mom: profile.momName, baby: profile.babyName))
            Button(action: onMore) {
                HStack {
                    Text("More about week \(content.week)")
                        .foregroundStyle(Theme.blushDeep)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
        } header: {
            Text(isCurrent ? "This week" : "Week \(content.week)")
        }
    }

    private func row(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Theme.blushDeep)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.bloom(.body))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
