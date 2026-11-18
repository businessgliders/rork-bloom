import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// What the activity shows right now, including what `staleDate` flipped.
private struct ActivityModel {
    let state: BloomActivityAttributes.ContentState
    let isStale: Bool
    /// "mom" or "partner": whose meds and meals these are (for the Eaten intent).
    let role: String
    /// "Jaismine's day" in the header.
    let dayTitle: String
    /// The taker's name when this phone belongs to someone else (the partner following mom's meds).
    var person: String? = nil

    init(context: ActivityViewContext<BloomActivityAttributes>) {
        state = context.state
        isStale = context.isStale
        let attributes = context.attributes
        role = attributes.takerRole
        let taker = attributes.takerName.trimmingCharacters(in: .whitespaces)
        let mom = attributes.momName.trimmingCharacters(in: .whitespaces)
        let name = taker.isEmpty ? (attributes.takerRole == "mom" ? mom : "") : taker
        dayTitle = name.isEmpty ? "Today" : "\(name)'s day"
        if attributes.isForSomeoneElse(viewerID: AppGroup.viewerID) {
            person = taker.isEmpty ? (attributes.takerRole == "partner" ? "Partner" : "Mom") : taker
        }
    }

    /// The window is still running (not passed its end).
    var windowRunning: Bool { state.hasWindow && !(isStale && state.staleReason == .windowEnds) }
    /// The window just ended and the app hasn't caught up yet.
    var windowJustEnded: Bool { state.hasWindow && isStale && state.staleReason == .windowEnds }
    /// The focus dose is due (either already, or its time has come since the last update).
    var doseDue: Bool {
        guard let dose = state.dose else { return false }
        return dose.isDue || (isStale && state.staleReason == .doseDue)
    }
    /// The meal shown, never while food has to wait.
    var meal: BloomActivityAttributes.MealRef? { windowRunning || windowJustEnded ? nil : state.meal }
    var mealDue: Bool {
        guard let meal else { return false }
        return meal.isDue || (isStale && state.staleReason == .mealDue)
    }
    /// The meal is the main row: nothing due sooner (board A). A due dose always leads (board B).
    var mealLeads: Bool {
        guard let meal else { return false }
        guard let dose = state.dose else { return true }
        return !doseDue && meal.startAt <= dose.scheduledAt
    }
    var allCaughtUp: Bool { state.dose == nil && !state.hasWindow && meal == nil }

    /// Terracotta while food waits, green for a meal or when done, rose for a dose.
    var accent: Color {
        if windowRunning && !doseDue { return Theme.terraDot }
        if mealLeads || allCaughtUp || windowJustEnded { return Theme.greenDot }
        return Theme.rose
    }

    var countText: String { "\(state.resolved) of \(state.total)" }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    /// "12:00" for the compact island.
    static func shortClock(_ date: Date) -> String {
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        return twelveHour ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) : clock(date)
    }
}

/// Colours for the activity in the current rendering mode.
///
/// Full colour keeps Bloom's cream card with every Theme token fixed to the
/// light or dark value for the current colour scheme, so the archived widget
/// can't pick the wrong one. Accented and vibrant modes (tinted or clear Lock
/// Screen styles, StandBy at night) use the system's primary and secondary
/// styles instead, so the system tint stays readable over any wallpaper.
private struct ActivityPalette {
    let fullColor: Bool
    let scheme: ColorScheme
    let onIsland: Bool

    init(mode: WidgetRenderingMode, scheme: ColorScheme, onIsland: Bool = false) {
        fullColor = mode == .fullColor
        self.scheme = scheme
        self.onIsland = onIsland
    }

    /// The Dynamic Island is always black, so its tokens use their dark values.
    static func island(mode: WidgetRenderingMode) -> ActivityPalette {
        ActivityPalette(mode: mode, scheme: .dark, onIsland: true)
    }

    private func style(_ color: Color, else system: some ShapeStyle) -> AnyShapeStyle {
        fullColor ? AnyShapeStyle(color.fixed(scheme)) : AnyShapeStyle(system)
    }

    func color(_ color: Color) -> Color? { fullColor ? color.fixed(scheme) : nil }

    var card: Color? { color(Theme.dayCanvas) }
    var headline: AnyShapeStyle {
        onIsland ? islandText(1) : style(Theme.dayText, else: .primary)
    }
    /// Small caption and time text: the secondary day tone, primary when tinted.
    var caption: AnyShapeStyle {
        onIsland ? islandText(0.75) : style(Theme.daySecondary, else: .primary)
    }
    var divider: AnyShapeStyle {
        if onIsland { return fullColor ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(.quaternary) }
        return style(Theme.dayDivider, else: .quaternary)
    }
    func accentText(_ color: Color) -> AnyShapeStyle { style(color, else: .primary) }
    func dot(_ color: Color) -> AnyShapeStyle { style(color, else: .primary) }
    /// Text on the black island.
    func islandText(_ opacity: Double) -> AnyShapeStyle {
        fullColor ? AnyShapeStyle(Color.white.opacity(opacity)) : AnyShapeStyle(opacity < 1 ? HierarchicalShapeStyle.secondary : .primary)
    }
}

struct MedsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BloomActivityAttributes.self) { context in
            // The background tint and action colour are set inside the view, where
            // the rendering mode and colour scheme can be read.
            LockScreenActivityView(model: ActivityModel(context: context))
                .widgetURL(CarryLink.meds)
        } dynamicIsland: { context in
            let model = ActivityModel(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandHeaderTitle(model: model)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandHeaderCount(model: model)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBody(model: model)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
            } compactLeading: {
                CompactLeading(model: model)
            } compactTrailing: {
                CompactTrailing(model: model)
            } minimal: {
                IslandMinimal(model: model)
            }
            .widgetURL(CarryLink.meds)
            .keylineTint(model.accent.fixed(.dark))
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ActivityPalette { ActivityPalette(mode: renderingMode, scheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(model: model, palette: palette)
            CardBody(model: model, palette: palette)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An opaque cream card in full colour: the tint alone is blended with the
        // wallpaper on newer Lock Screens, which washed the text out.
        .background(palette.card ?? .clear)
        .activityBackgroundTint(palette.card)
        .activitySystemActionForegroundColor(palette.color(Theme.rose))
    }
}

/// CarryMark · "Jaismine's day" · "2 of 5".
private struct CardHeader: View {
    var model: ActivityModel
    var palette: ActivityPalette

    var body: some View {
        HStack(spacing: 6) {
            CarryMark(size: 12, arcColor: palette.color(Theme.rose) ?? .primary,
                      dotColor: palette.color(Theme.terraDot) ?? .primary)
                .widgetAccentable()
            Text(model.dayTitle)
                .font(.system(size: 13))
                .foregroundStyle(palette.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text(model.countText)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(palette.caption)
        }
    }
}

/// The main row (one button at most), then one quiet line for what comes after.
/// Shared by the Lock Screen and the expanded Dynamic Island.
private struct CardBody: View {
    var model: ActivityModel
    var palette: ActivityPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            main
            if let then = thenLine {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 0.5)
                then
            }
        }
    }

    @ViewBuilder
    private var main: some View {
        let state = model.state
        if model.windowRunning, !model.doseDue, let start = state.windowStart, let end = state.windowEnd {
            WindowRow(start: start, end: end, reason: state.windowReason, palette: palette)
        } else if let dose = state.dose, model.doseDue {
            MainRow(dot: Theme.rose, title: dose.name, subline: Text(dueLine(dose)), palette: palette) {
                Button(intent: MarkDoseTakenIntent(medID: dose.medID, scheduledAt: dose.scheduledAt)) {
                    TakenLabel(palette: palette)
                }
                .buttonStyle(.plain)
            }
        } else if let meal = model.meal, model.mealLeads {
            MainRow(dot: Theme.greenDot, title: meal.title, subline: mealLine(meal), palette: palette) {
                Button(intent: MarkMealEatenIntent(role: model.role, meal: meal.key)) {
                    EatenLabel(palette: palette)
                }
                .buttonStyle(.plain)
            }
        } else if let dose = state.dose {
            MainRow(dot: Theme.rose, title: dose.name, subline: upcomingLine(dose.scheduledAt), palette: palette) { EmptyView() }
        } else if model.windowJustEnded {
            MainRow(dot: Theme.greenDot, title: model.person == nil ? "You can eat again" : "Food is OK again",
                    subline: Text("The no-food window is over"), palette: palette) { EmptyView() }
        } else {
            let done = state.total > 0 && state.resolved == state.total
            MainRow(dot: Theme.greenDot, title: done ? "All done today" : "All caught up",
                    subline: Text("\(state.resolved) of \(state.total) doses logged"), palette: palette) { EmptyView() }
        }
    }

    /// "Then breakfast · 9:30 AM" under a dose, "Then Thyroid · 12:30 PM" under a meal,
    /// or the running window under a due dose.
    private var thenLine: AnyView? {
        let state = model.state
        if model.windowRunning, model.doseDue, let end = state.windowEnd {
            let reason = state.windowReason.map { " · \($0)" } ?? ""
            return AnyView(QuietLine(dot: Theme.terraDot, text: "No food until \(ActivityModel.clock(end))\(reason)",
                                     color: Theme.terraText, palette: palette))
        }
        if let meal = model.meal, !model.mealLeads {
            return AnyView(QuietLine(dot: Theme.greenDot,
                                     text: "Then \(meal.title.lowercased()) · \(ActivityModel.clock(meal.startAt))",
                                     color: nil, palette: palette))
        }
        if model.mealLeads, let dose = state.dose {
            return AnyView(QuietLine(dot: Theme.rose, text: "Then \(dose.name) · \(ActivityModel.clock(dose.scheduledAt))",
                                     color: nil, palette: palette))
        }
        return nil
    }

    private func dueLine(_ dose: BloomActivityAttributes.DoseRef) -> String {
        let more = model.state.otherDueCount > 0 ? " · +\(model.state.otherDueCount) more" : ""
        return "Due now · \(ActivityModel.clock(dose.scheduledAt))\(more)"
    }

    /// "12:00 PM · in 7:59" (counts down), or "Now · 12:00 PM".
    private func mealLine(_ meal: BloomActivityAttributes.MealRef) -> Text {
        if model.mealDue || meal.startAt <= .now { return Text("Now · \(ActivityModel.clock(meal.startAt))") }
        return upcomingLine(meal.startAt)
    }

    private func upcomingLine(_ date: Date) -> Text {
        Text("\(ActivityModel.clock(date)) · in ") + Text(timerInterval: Date.now...max(Date.now, date), countsDown: true)
    }
}

private struct MainRow<Trailing: View>: View {
    var dot: Color
    var title: String
    var subline: Text
    var palette: ActivityPalette
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(palette.dot(dot))
                .frame(width: 9, height: 9)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                subline
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(palette.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The button keeps its full width; the live timer in the subline is greedy otherwise.
            trailing
                .fixedSize()
                .layoutPriority(2)
        }
    }
}

/// Board C: the terracotta ring with the countdown.
private struct WindowRow: View {
    var start: Date
    var end: Date
    var reason: String?
    var palette: ActivityPalette

    var body: some View {
        HStack(spacing: 14) {
            ProgressView(timerInterval: start...end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(palette.color(Theme.terraDot))
            .frame(width: 48, height: 48)
            .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(reason.map { "No food · \($0)" } ?? "No food")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accentText(Theme.terraText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(timerInterval: start...end, countsDown: true)
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("until \(ActivityModel.clock(end))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(palette.caption)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct QuietLine: View {
    var dot: Color
    var text: String
    var color: Color?
    var palette: ActivityPalette

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(palette.dot(dot))
                .frame(width: 6, height: 6)
                .widgetAccentable()
            Text(text)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(color.map { palette.accentText($0) } ?? palette.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The rose "Taken" capsule.
private struct TakenLabel: View {
    var palette: ActivityPalette

    var body: some View {
        let label = Text("Taken")
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(height: 40)
        if palette.fullColor {
            label
                .foregroundStyle(.white)
                .background(Theme.rose.fixed(palette.scheme), in: .capsule)
        } else {
            // Tinted modes: an outlined capsule in the system tint, readable on any wallpaper.
            label
                .foregroundStyle(.primary)
                .background(.quaternary, in: .capsule)
                .overlay(Capsule().strokeBorder(.primary, lineWidth: 1.5))
                .widgetAccentable()
        }
    }
}

/// "Eaten": the meal check's dashed green ring with the label beside it, on a green-tinted capsule.
private struct EatenLabel: View {
    var palette: ActivityPalette
    /// The meal check's ring colour, #5E8A5A in both schemes.
    private static let ring = Theme.greenDot.fixed(.light)

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(palette.fullColor ? AnyShapeStyle(Self.ring) : AnyShapeStyle(.primary),
                              style: StrokeStyle(lineWidth: 1.5, dash: [3.2, 2.6]))
                .frame(width: 30, height: 30)
            Text("Eaten")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.accentText(Theme.greenText))
        }
        .padding(.leading, 5)
        .padding(.trailing, 16)
        .frame(height: 40)
        .background(palette.fullColor ? AnyShapeStyle(Theme.greenTint.fixed(palette.scheme)) : AnyShapeStyle(.quaternary),
                    in: .capsule)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eaten")
    }
}

// MARK: - Dynamic Island

private struct IslandHeaderTitle: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        HStack(spacing: 6) {
            CarryMark(size: 12, arcColor: palette.color(Theme.rose) ?? .primary,
                      dotColor: palette.color(Theme.terraDot) ?? .primary)
            Text(model.dayTitle)
                .font(.system(size: 13))
                .foregroundStyle(palette.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IslandHeaderCount: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Text(model.countText)
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(ActivityPalette.island(mode: renderingMode).caption)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct IslandBody: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        CardBody(model: model, palette: .island(mode: renderingMode))
    }
}

/// The state dot: terracotta for a no-food window, green for a meal or done, rose for a dose.
private struct IslandDot: View {
    var model: ActivityModel
    var size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        Circle()
            .fill(palette.dot(model.accent))
            .frame(width: size, height: size)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// Board D: "● Lunch" when the meal leads, otherwise the state dot.
private struct CompactLeading: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if model.mealLeads, let meal = model.meal {
            HStack(spacing: 6) {
                IslandDot(model: model, size: 8)
                Text(meal.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ActivityPalette.island(mode: renderingMode).islandText(1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 76, alignment: .leading)
            }
            .padding(.leading, 2)
        } else {
            IslandDot(model: model, size: 10)
        }
    }
}

private struct CompactTrailing: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            Text(timerInterval: start...end, countsDown: true)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.accentText(Theme.terraDot))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 56)
        } else if model.doseDue {
            Text("Due")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentText(Theme.rose))
        } else if model.mealLeads, let meal = model.meal {
            Text(ActivityModel.shortClock(meal.startAt))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.accentText(Theme.greenDot))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 56, alignment: .trailing)
        } else if let dose = model.state.dose {
            Text(dose.scheduledAt, style: .time)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.accentText(Theme.rose))
                .frame(maxWidth: 56)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accentText(Theme.greenCheck))
        }
    }
}

private struct IslandMinimal: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            ProgressView(timerInterval: start...end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(ActivityPalette.island(mode: renderingMode).color(Theme.terraDot))
        } else {
            IslandDot(model: model, size: 12)
        }
    }
}
