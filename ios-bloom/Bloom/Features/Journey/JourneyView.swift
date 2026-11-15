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
                    ScrollView {
                        weekSection(profile: profile, age: age, weekNumber: weekNumber)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 32)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                    }
                } secondary: {
                    // Wide, right pane: the full timeline.
                    TimelinePane()
                } compact: {
                    // Regular iPhones, Duo outer display, tall inner display.
                    ScrollView {
                        VStack(spacing: 28) {
                            weekSection(profile: profile, age: age, weekNumber: weekNumber)
                            TimelineStrip(
                                milestones: store.sortedMilestones,
                                onSelect: { editingMilestone = MilestoneEditorItem(milestone: $0) },
                                onAdd: { editingMilestone = MilestoneEditorItem(milestone: nil) }
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                    .background(BloomBackground())
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        .tint(Theme.textSecondary)
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
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
    private func weekSection(profile: PregnancyProfile, age: GestationalAge, weekNumber: Int) -> some View {
        VStack(spacing: 28) {
            WeekHeroView(
                profile: profile,
                age: age,
                browseWeek: $browseWeek,
                onEditDates: { showDates = true },
                onOpenWeek: { detailWeek = WeekSheetItem(week: weekNumber) }
            )

            if let content = WeekLibrary.week(weekNumber) {
                ThisWeekCard(content: content, profile: profile, isCurrent: browseWeek == nil) {
                    detailWeek = WeekSheetItem(week: weekNumber)
                }
            }
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

struct WeekHeroView: View {
    var profile: PregnancyProfile
    var age: GestationalAge
    @Binding var browseWeek: Int?
    var onEditDates: () -> Void
    var onOpenWeek: () -> Void

    @State private var bob = false

    private var shownWeek: Int { browseWeek ?? age.contentWeek }
    private var content: WeekContent? { WeekLibrary.week(shownWeek) }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(caption)
                    .font(.bloom(.subheadline, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 4) {
                    chevron("chevron.left", enabled: shownWeek > 1) { shift(-1) }
                    Text(browseWeek == nil ? age.headline : "Week \(shownWeek)")
                        .font(.bloom(.largeTitle, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .frame(maxWidth: .infinity)
                    chevron("chevron.right", enabled: shownWeek < 42) { shift(1) }
                }

                if browseWeek == nil {
                    Button(action: onEditDates) {
                        Label("\(age.daysToGoText) · Due \(profile.dueDate.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "pencil")
                            .font(.bloom(.subheadline, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Theme.blushSoft, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint("Edit due date")
                } else {
                    Button {
                        Haptics.select()
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { browseWeek = nil }
                    } label: {
                        Label("Back to today", systemImage: "arrow.uturn.backward")
                            .font(.bloom(.subheadline, weight: .bold))
                            .foregroundStyle(Theme.sageDeep)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Theme.sageSoft, in: .capsule)
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            Button(action: onOpenWeek) {
                ZStack {
                    ProgressRing(
                        progress: browseWeek == nil ? age.ringProgress : Double(shownWeek * 7) / 280,
                        lineWidth: 20
                    )
                    VStack(spacing: 10) {
                        ZStack(alignment: .topTrailing) {
                            BlobShape(seed: shownWeek)
                                .fill(Theme.peachSoft)
                                .frame(width: 200, height: 170)
                            Text(content?.emoji ?? "🌱")
                                .font(.system(size: 92))
                                .frame(width: 200, height: 170)
                                .offset(y: bob ? -5 : 4)
                                .contentTransition(.interpolate)
                            ShineMarks()
                                .offset(x: -14, y: 8)
                        }
                        VStack(spacing: 4) {
                            Text("\(profile.babyName) is \(content?.sizeSentence ?? "growing")")
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            if let measurement = content?.measurementText {
                                Text(measurement)
                                    .font(.bloom(.subheadline))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                }
                .fittedSquare(330)
                .padding(.horizontal, 4)
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.babyName) is \(content?.sizeSentence ?? ""). \(content?.measurementText ?? "")")
            .accessibilityHint("Opens this week's details")
        }
        .padding(.top, 4)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shownWeek)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { bob = true }
        }
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
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textSecondary.opacity(enabled ? 1 : 0.3))
                .frame(width: 36, height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous week" : "Next week")
    }

    private func shift(_ delta: Int) {
        let target = min(max(shownWeek + delta, 1), 42)
        guard target != shownWeek else { return }
        Haptics.select()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            browseWeek = target == age.contentWeek ? nil : target
        }
    }
}

// MARK: - This week

struct ThisWeekCard: View {
    var content: WeekContent
    var profile: PregnancyProfile
    var isCurrent: Bool
    var onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isCurrent ? "This week" : "Week \(content.week)")
                .font(.bloom(.title, weight: .heavy))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 8)

            row(symbol: "shoeprints.fill", tint: Theme.sage, title: profile.babyName,
                text: content.babyText(name: profile.babyName))
            Divider().overlay(Theme.ringTrack)
            row(symbol: "person.fill", tint: Theme.blush, title: profile.momName,
                text: content.momText(name: profile.momName))
            Divider().overlay(Theme.ringTrack)
            row(symbol: "person.2.fill", tint: Theme.peach,
                title: profile.hasPartner ? profile.partnerName : "Partner",
                text: content.partnerText(mom: profile.momName, baby: profile.babyName))

            Button(action: onMore) {
                HStack(spacing: 6) {
                    Text("More about week \(content.week)")
                    Image(systemName: "arrow.right")
                }
                .font(.bloom(.subheadline, weight: .bold))
                .foregroundStyle(Theme.blushDeep)
            }
            .padding(.top, 8)
        }
        .bloomCard(padding: 22)
    }

    private func row(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint, in: .circle)
            Text("\(Text("\(title):").fontWeight(.heavy)) \(text)")
                .font(.bloom(.body))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
