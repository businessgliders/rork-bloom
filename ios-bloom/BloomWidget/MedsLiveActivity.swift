import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// What the activity shows right now, including what `staleDate` flipped.
private struct ActivityModel {
    let state: BloomActivityAttributes.ContentState
    let isStale: Bool
    /// The taker's name when this phone belongs to someone else (the partner following mom's meds).
    var person: String? = nil

    init(context: ActivityViewContext<BloomActivityAttributes>) {
        state = context.state
        isStale = context.isStale
        let attributes = context.attributes
        if attributes.isForSomeoneElse(viewerID: AppGroup.viewerID) {
            let name = attributes.takerName.trimmingCharacters(in: .whitespaces)
            person = name.isEmpty ? (attributes.takerRole == "partner" ? "Partner" : "Mom") : name
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
    var allCaughtUp: Bool { state.dose == nil && !state.hasWindow }

    var headline: String {
        if allCaughtUp { return state.total > 0 && state.resolved == state.total ? "All done today" : "All caught up" }
        if let person {
            if let dose = state.dose, doseDue { return "\(person): time for \(dose.name)" }
            if windowRunning { return "\(person): no food yet" }
            if windowJustEnded { return "\(person) can eat again" }
            if let dose = state.dose { return "\(person): next \(dose.name)" }
            return person
        }
        if let dose = state.dose, doseDue { return "Time for \(dose.name)" }
        if windowRunning { return "No food yet" }
        if windowJustEnded { return "You can eat again" }
        if let dose = state.dose { return "Next: \(dose.name)" }
        return "Bloom"
    }

    /// The headline for someone else's running window reads into the big countdown
    /// beside it: "Leo: no food for  41:58". The countdown isn't repeated inline so
    /// it fits narrow screens (folded iPhone Duo).
    var headlineText: Text {
        if let person, windowRunning, !doseDue {
            return Text("\(person): no food for")
        }
        return Text(headline)
    }

    var subline: String {
        if allCaughtUp { return "\(state.resolved) of \(state.total) doses logged 🌷" }
        if let dose = state.dose, doseDue {
            let detail = dose.detail.trimmingCharacters(in: .whitespaces)
            let since = "since \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))"
            return detail.isEmpty ? "Due \(since)" : "\(detail) · due \(since)"
        }
        if windowRunning, let end = state.windowEnd {
            return "Eat again at \(end.formatted(date: .omitted, time: .shortened))"
        }
        if windowJustEnded { return person == nil ? "Your no-food window is over 🍽️" : "The no-food window is over 🍽️" }
        if let dose = state.dose { return "at \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))" }
        return ""
    }

    var emoji: String {
        if allCaughtUp { return "🌷" }
        if windowRunning && !doseDue { return "⏳" }
        if windowJustEnded && !doseDue { return "🍽️" }
        return state.dose?.emoji ?? "💊"
    }

    var accent: Color { windowRunning && !doseDue ? Theme.coral : (allCaughtUp || windowJustEnded ? Theme.sage : Theme.blush) }
    var accentSoft: Color { windowRunning && !doseDue ? Theme.coralSoft : (allCaughtUp || windowJustEnded ? Theme.sageSoft : Theme.blushSoft) }
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

    init(mode: WidgetRenderingMode, scheme: ColorScheme) {
        fullColor = mode == .fullColor
        self.scheme = scheme
    }

    /// The Dynamic Island is always black, so its tokens use their dark values.
    static func island(mode: WidgetRenderingMode) -> ActivityPalette {
        ActivityPalette(mode: mode, scheme: .dark)
    }

    private func style(_ color: Color, else system: some ShapeStyle) -> AnyShapeStyle {
        fullColor ? AnyShapeStyle(color.fixed(scheme)) : AnyShapeStyle(system)
    }

    func color(_ color: Color) -> Color? { fullColor ? color.fixed(scheme) : nil }

    var card: Color? { color(Theme.canvas) }
    var headline: AnyShapeStyle { style(Theme.text, else: .primary) }
    /// Small caption and time text: the deepest secondary tone, primary when tinted.
    var caption: AnyShapeStyle { style(Theme.textCaption, else: .primary) }
    func accentText(_ color: Color) -> AnyShapeStyle { style(color, else: .primary) }
    func blob(_ color: Color) -> AnyShapeStyle { style(color, else: .quaternary) }
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
        } dynamicIsland: { context in
            let model = ActivityModel(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandBlob(model: model)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTrailing(model: model)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandCenter(model: model)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBottom(model: model, onIsland: true)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Text(model.emoji).font(.system(size: 16))
            } compactTrailing: {
                CompactTrailing(model: model)
            } minimal: {
                IslandMinimal(model: model)
            }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                EmojiBlob(emoji: model.emoji, size: 50, style: palette.blob(model.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bloom · \(model.state.resolved)/\(model.state.total) today".uppercased())
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.4)
                        .foregroundStyle(palette.caption)
                        .lineLimit(1)
                        // Folded iPhone Duo is narrow: shrink a little before truncating.
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    model.headlineText
                        .font(.bloom(.title3, weight: .heavy))
                        .foregroundStyle(palette.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(model.subline)
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(palette.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd, model.doseDue {
                    // Both a due dose and a running window: show the countdown here, the button below.
                    timer(start...end, size: 22, color: Theme.coralDeep, maxWidth: 96)
                } else if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
                    timer(start...end, size: 28, color: Theme.coralDeep, maxWidth: 112)
                } else if let dose = model.state.dose, !model.doseDue {
                    timer(Date.now...max(Date.now, dose.scheduledAt), size: 22, color: Theme.blushDeep, maxWidth: 96)
                }
            }
            ActivityBottom(model: model, onIsland: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An opaque cream card in full colour: the tint alone is blended with the
        // wallpaper on newer Lock Screens, which washed the text out.
        .background(palette.card ?? .clear)
        .activityBackgroundTint(palette.card)
        .activitySystemActionForegroundColor(palette.color(Theme.blushDeep))
    }

    private func timer(_ range: ClosedRange<Date>, size: CGFloat, color: Color, maxWidth: CGFloat) -> some View {
        Text(timerInterval: range, countsDown: true)
            .font(.system(size: size, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(palette.accentText(color))
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: maxWidth)
            .widgetAccentable()
    }
}

/// The Taken button when a dose is due, otherwise the window progress bar.
private struct ActivityBottom: View {
    var model: ActivityModel
    var onIsland: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ActivityPalette {
        onIsland ? .island(mode: renderingMode) : ActivityPalette(mode: renderingMode, scheme: colorScheme)
    }
    private var smallText: AnyShapeStyle { onIsland ? palette.islandText(0.8) : palette.caption }

    var body: some View {
        if let dose = model.state.dose, model.doseDue {
            HStack(spacing: 10) {
                Button(intent: MarkDoseTakenIntent(medID: dose.medID, scheduledAt: dose.scheduledAt)) {
                    takenLabel
                }
                .buttonStyle(.plain)
                if model.state.otherDueCount > 0 {
                    Text("+\(model.state.otherDueCount) more due")
                        .font(.bloom(.caption, weight: .bold))
                        .foregroundStyle(smallText)
                }
            }
        } else if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(timerInterval: start...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(palette.color(Theme.coral))
                if let reason = model.state.windowReason {
                    Text("Because of \(reason) · counted from when \(model.person ?? "you") took it")
                        .font(.bloom(.caption, weight: .semibold))
                        .foregroundStyle(smallText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        } else if model.state.total > 0 {
            ProgressView(value: Double(model.state.resolved), total: Double(model.state.total))
                .tint(palette.color(Theme.sage))
        }
    }

    @ViewBuilder
    private var takenLabel: some View {
        let label = Label("Taken", systemImage: "checkmark")
            .font(.bloom(.headline, weight: .heavy))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        if palette.fullColor {
            label
                .foregroundStyle(.white)
                .background(Theme.roseButton, in: .capsule)
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

// MARK: - Dynamic Island pieces

private struct IslandBlob: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        EmojiBlob(emoji: model.emoji, size: 44,
                  style: palette.fullColor ? AnyShapeStyle(model.accent.fixed(.dark).opacity(0.35)) : AnyShapeStyle(.quaternary))
    }
}

private struct IslandCenter: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        VStack(alignment: .leading, spacing: 2) {
            model.headlineText
                .font(.bloom(.headline, weight: .heavy))
                .foregroundStyle(palette.islandText(1))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(model.subline)
                .font(.bloom(.caption, weight: .semibold))
                .foregroundStyle(palette.islandText(0.85))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IslandTrailing: View {
    var model: ActivityModel
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = ActivityPalette.island(mode: renderingMode)
        if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            VStack(alignment: .trailing, spacing: 0) {
                Text(timerInterval: start...end, countsDown: true)
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(palette.accentText(Theme.coral))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 88)
                Text("no food")
                    .font(.bloom(.caption2, weight: .bold))
                    .foregroundStyle(palette.islandText(0.8))
            }
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(model.state.resolved)/\(model.state.total)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(palette.accentText(Theme.sage))
                Text("today")
                    .font(.bloom(.caption2, weight: .bold))
                    .foregroundStyle(palette.islandText(0.8))
            }
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
                .font(.system(size: 14, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(palette.accentText(Theme.coral))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 56)
        } else if model.doseDue {
            Text("Due")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(palette.accentText(Theme.blush))
        } else if let dose = model.state.dose {
            Text(dose.scheduledAt, style: .time)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(palette.accentText(Theme.blush))
                .frame(maxWidth: 56)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accentText(Theme.sage))
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
                Text(model.emoji).font(.system(size: 11))
            }
            .progressViewStyle(.circular)
            .tint(ActivityPalette.island(mode: renderingMode).color(Theme.coral))
        } else {
            Text(model.emoji).font(.system(size: 14))
        }
    }
}
