import SwiftUI

/// Journey: only the baby. Week and days, the ring with the size comparison, the due date
/// and This week (Baby / Mom / Partner). The milestone timeline has its own tab.
/// Open iPhone Duo (wide): the ring, centred and large, on the left; This week scrolls on its own
/// on the right. Folded Duo and regular iPhones: one column, ring first.
struct JourneyView: View {
    @Environment(AppStore.self) private var store

    /// Week being previewed with the chevrons; nil = today.
    @State private var browseWeek: Int?
    @State private var showDates = false
    @State private var showSettings = false
    @State private var detailWeek: WeekSheetItem?

    var body: some View {
        NavigationStack {
            if let profile = store.profile {
                let age = profile.progress(on: store.now)
                let weekNumber = browseWeek ?? age.contentWeek
                AdaptiveColumns {
                    // Wide, left pane: the ring, as large as the pane allows, centred.
                    hero(profile: profile, age: age, weekNumber: weekNumber, expanded: true)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } secondary: {
                    // Wide, right pane: This week, scrolling on its own.
                    ScrollView {
                        thisWeek(profile: profile, weekNumber: weekNumber)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("journey-this-week-pane")
                } compact: {
                    // Regular iPhones, Duo outer display, tall inner display.
                    ScrollView {
                        VStack(spacing: 28) {
                            hero(profile: profile, age: age, weekNumber: weekNumber, expanded: false)
                            thisWeek(profile: profile, weekNumber: weekNumber)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                    .background(CarryBackground())
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
                .sheet(isPresented: $showDates) {
                    NavigationStack { EditDatesView() }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .sheet(item: $detailWeek) { item in
                    WeekDetailSheet(week: item.week, profile: profile)
                }
            }
        }
    }

    private func hero(profile: PregnancyProfile, age: GestationalAge, weekNumber: Int, expanded: Bool) -> some View {
        WeekHeroView(
            profile: profile,
            age: age,
            browseWeek: $browseWeek,
            expanded: expanded,
            onEditDates: { showDates = true },
            onOpenWeek: { detailWeek = WeekSheetItem(week: weekNumber) }
        )
    }

    @ViewBuilder
    private func thisWeek(profile: PregnancyProfile, weekNumber: Int) -> some View {
        if let content = WeekLibrary.week(weekNumber) {
            ThisWeekCard(content: content, profile: profile, isCurrent: browseWeek == nil) {
                detailWeek = WeekSheetItem(week: weekNumber)
            }
        }
    }
}

struct WeekSheetItem: Identifiable {
    let week: Int
    var id: Int { week }
}

struct MilestoneEditorItem: Identifiable {
    let id = UUID()
    let milestone: Milestone?
}

// MARK: - Hero

/// The Journey hero: the Carry arc as pregnancy progress (week / 40), the dot growing each
/// trimester, the week number in the hole, and the lowercase "carry" wordmark over the arc.
/// The arc draws in from 0 every time the tab opens. Designed at 330 pt.
struct CarryWeekMark: View {
    var week: Int
    var progress: Double
    var trimester: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private let size: CGFloat = 268
    private var dotScale: CGFloat { [0.42, 0.56, 0.7][max(0, min(2, trimester - 1))] }

    var body: some View {
        ZStack {
            CarryMark(size: size, progress: shown, dotScale: dotScale, dotOffset: 0.19,
                      trackColor: Theme.ringTrack, breathing: true)
            VStack(spacing: -2) {
                Text("\(week)")
                    .font(.system(size: 66, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: Double(week)))
                Text(week == 1 ? "week" : "weeks")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .offset(x: -size * 0.09, y: 2)
        }
        .frame(width: size, height: size)
        // The wordmark sits on the arc's upper left: the arc runs behind its "c".
        .overlay(alignment: .topLeading) {
            Text("carry")
                .font(.system(size: 62, weight: .regular, design: .serif).italic())
                .foregroundStyle(Theme.rose.opacity(0.85))
                .fixedSize()
                .offset(x: -size * 0.08, y: -size * 0.13)
                .accessibilityHidden(true)
        }
        .frame(width: 330, height: 330, alignment: .center)
        .offset(y: 14)
        .onAppear { drawIn() }
        .onChange(of: progress) { _, new in
            withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.9)) { shown = new }
        }
    }

    private func drawIn() {
        guard !reduceMotion else { shown = progress; return }
        shown = 0
        withAnimation(.easeOut(duration: 1.1).delay(0.12)) { shown = progress }
    }
}

struct WeekHeroView: View {
    var profile: PregnancyProfile
    var age: GestationalAge
    @Binding var browseWeek: Int?
    /// Wide pane: the ring grows to fill the space left under the header, centred.
    var expanded = false
    var onEditDates: () -> Void
    var onOpenWeek: () -> Void


    private var shownWeek: Int { browseWeek ?? age.contentWeek }
    private var targetProgress: Double {
        browseWeek == nil ? age.ringProgress : Double(shownWeek * 7) / 280
    }
    private var shownTrimester: Int { shownWeek < 14 ? 1 : (shownWeek < 28 ? 2 : 3) }
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
                VStack(spacing: expanded ? 18 : 12) {
                    CarryWeekMark(week: shownWeek, progress: targetProgress, trimester: shownTrimester)
                        // Drawn for 330 pt; grows with the bigger pane like the old ring did.
                        .frame(width: 330, height: 330)
                        .scaleEffect(expanded ? 440 / 330 : 1)
                        .fittedSquare(expanded ? 440 : 330)
                        .padding(.horizontal, 4)
                    HStack(spacing: 10) {
                        Text(content?.emoji ?? "🌱")
                            .font(.system(size: 34))
                            .contentTransition(.interpolate)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(profile.babyName) is \(content?.sizeSentence ?? "growing")")
                                .font(.bloom(.headline, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            if let measurement = content?.measurementText {
                                Text(measurement)
                                    .font(.bloom(.subheadline))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 420)
                }
            }
            .frame(maxHeight: expanded ? .infinity : nil)
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.babyName) is \(content?.sizeSentence ?? ""). \(content?.measurementText ?? "")")
            .accessibilityHint("Opens this week's details")
        }
        .padding(.top, 4)
        .frame(maxHeight: expanded ? .infinity : nil)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shownWeek)
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
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textSecondary.opacity(0.3))
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
