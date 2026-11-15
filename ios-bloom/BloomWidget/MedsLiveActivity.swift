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
        if allCaughtUp { return "\(state.resolved) of \(state.total) doses logged" }
        if let dose = state.dose, doseDue {
            let detail = dose.detail.trimmingCharacters(in: .whitespaces)
            let since = "since \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))"
            return detail.isEmpty ? "Due \(since)" : "\(detail) · due \(since)"
        }
        if windowRunning, let end = state.windowEnd {
            return "Eat again at \(end.formatted(date: .omitted, time: .shortened))"
        }
        if windowJustEnded { return person == nil ? "Your no-food window is over" : "The no-food window is over" }
        if let dose = state.dose { return "at \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))" }
        return ""
    }

    var symbol: String {
        if allCaughtUp { return "checkmark" }
        if windowRunning && !doseDue { return "hourglass" }
        if windowJustEnded && !doseDue { return "fork.knife" }
        return "pills.fill"
    }

    /// Solid fill for the status circle and keyline.
    var accent: Color { windowRunning && !doseDue ? Theme.coral : (allCaughtUp || windowJustEnded ? Theme.sage : Theme.blush) }
    /// Text / glyph colour on the system background.
    var accentDeep: Color { windowRunning && !doseDue ? Theme.coralDeep : (allCaughtUp || windowJustEnded ? Theme.sageDeep : Theme.blushDeep) }
}

struct MedsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BloomActivityAttributes.self) { context in
            LockScreenActivityView(model: ActivityModel(context: context))
                .activityBackgroundTint(Theme.surface)
                .activitySystemActionForegroundColor(Theme.blushDeep)
        } dynamicIsland: { context in
            let model = ActivityModel(context: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(symbol: model.symbol, size: 40, tint: model.accent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTrailing(model: model)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        model.headlineText
                            .font(.bloom(.headline, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(model.subline)
                            .font(.bloom(.caption))
                            .foregroundStyle(Color(white: 0.72))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBottom(model: model, onDark: true)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: model.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.accentDeep)
            } compactTrailing: {
                CompactTrailing(model: model)
            } minimal: {
                if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
                    ProgressView(timerInterval: start...end, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: model.symbol).font(.system(size: 9, weight: .semibold))
                    }
                    .progressViewStyle(.circular)
                    .tint(Theme.coral)
                } else {
                    Image(systemName: model.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.accentDeep)
                }
            }
            .keylineTint(model.accent)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    var model: ActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatusIcon(symbol: model.symbol, size: 40, tint: model.accent)
                VStack(alignment: .leading, spacing: 2) {
                    WidgetCaption(text: "Bloom · \(model.state.resolved)/\(model.state.total) today", color: Theme.textSecondary)
                    model.headlineText
                        .font(.bloom(.headline, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(model.subline)
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd, model.doseDue {
                    // Both a due dose and a running window: show the countdown here, the button below.
                    Text(timerInterval: start...end, countsDown: true)
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.coralDeep)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 96)
                } else if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
                    Text(timerInterval: start...end, countsDown: true)
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.coralDeep)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 112)
                } else if let dose = model.state.dose, !model.doseDue {
                    Text(timerInterval: Date.now...max(Date.now, dose.scheduledAt), countsDown: true)
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.blushDeep)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 96)
                }
            }
            ActivityBottom(model: model, onDark: false)
        }
        .padding(16)
    }
}

/// The Taken button when a dose is due, otherwise the window progress bar.
private struct ActivityBottom: View {
    var model: ActivityModel
    var onDark: Bool

    var body: some View {
        if let dose = model.state.dose, model.doseDue {
            HStack(spacing: 10) {
                Button(intent: MarkDoseTakenIntent(medID: dose.medID, scheduledAt: dose.scheduledAt)) {
                    Label("Taken", systemImage: "checkmark")
                        .font(.bloom(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.blush, in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                if model.state.otherDueCount > 0 {
                    Text("+\(model.state.otherDueCount) more due")
                        .font(.bloom(.caption))
                        .foregroundStyle(onDark ? Color(white: 0.72) : Theme.textSecondary)
                }
            }
        } else if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(timerInterval: start...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(Theme.coral)
                if let reason = model.state.windowReason {
                    Text("Because of \(reason) · counted from when \(model.person ?? "you") took it")
                        .font(.bloom(.caption2))
                        .foregroundStyle(onDark ? Color(white: 0.72) : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        } else if model.state.total > 0 {
            ProgressView(value: Double(model.state.resolved), total: Double(model.state.total))
                .tint(Theme.sageDeep)
        }
    }
}

// MARK: - Dynamic Island pieces

private struct IslandTrailing: View {
    var model: ActivityModel

    var body: some View {
        if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            VStack(alignment: .trailing, spacing: 0) {
                Text(timerInterval: start...end, countsDown: true)
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.coralDeep)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 88)
                Text("no food")
                    .font(.bloom(.caption2))
                    .foregroundStyle(Color(white: 0.72))
            }
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(model.state.resolved)/\(model.state.total)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.sageDeep)
                Text("today")
                    .font(.bloom(.caption2))
                    .foregroundStyle(Color(white: 0.72))
            }
        }
    }
}

private struct CompactTrailing: View {
    var model: ActivityModel

    var body: some View {
        if model.windowRunning, let start = model.state.windowStart, let end = model.state.windowEnd {
            Text(timerInterval: start...end, countsDown: true)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.coralDeep)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 56)
        } else if model.doseDue {
            Text("Due")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
        } else if let dose = model.state.dose {
            Text(dose.scheduledAt, style: .time)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
                .frame(maxWidth: 56)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sageDeep)
        }
    }
}
