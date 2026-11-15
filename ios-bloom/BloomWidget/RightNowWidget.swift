import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Entry

nonisolated struct RightNowEntry: TimelineEntry {
    let date: Date
    let onboarded: Bool
    let today: [DoseInstance]
    let due: [DoseInstance]
    let next: DoseInstance?
    /// A confirmed no-food window running at `date`.
    let window: NoFoodWindow?
    /// The next planned pause later today.
    let nextWindow: NoFoodWindow?

    var resolved: Int { today.filter { !$0.isPending }.count }
    var total: Int { today.count }
    var allDone: Bool { total > 0 && resolved == total }

    static func make(_ snapshot: SharedSnapshot, at date: Date) -> RightNowEntry {
        let today = snapshot.instances(on: date)
        let rn = MedsEngine.rightNow(instances: today, now: date, carryOver: snapshot.carryOver(into: date))
        var window: NoFoodWindow?
        var nextWindow: NoFoodWindow?
        switch rn.food {
        case .noFood(let w): if w.isConfirmed { window = w }
        case .foodOK(let w): nextWindow = w
        case .holdForDose: break
        }
        return RightNowEntry(
            date: date,
            onboarded: snapshot.onboardingComplete && snapshot.profile != nil,
            today: today,
            due: rn.due,
            next: rn.next,
            window: window,
            nextWindow: nextWindow
        )
    }

    static var sample: RightNowEntry {
        let now = Date.now
        let med = Medication(name: "Levothyroxine", dose: "1 tablet", emoji: "💊",
                             times: [DoseTime(date: now)], foodRule: .emptyStomach, noFoodAfterMinutes: 30)
        let iron = Medication(name: "Iron", dose: "", emoji: "🍊", times: [DoseTime(hour: 13, minute: 0)], foodRule: .withFood)
        let first = DoseInstance(medication: med, scheduledAt: now.addingTimeInterval(-300), log: nil)
        let second = DoseInstance(medication: iron, scheduledAt: now.addingTimeInterval(3 * 3600), log: nil)
        return RightNowEntry(date: now, onboarded: true, today: [first, second], due: [first], next: second, window: nil, nextWindow: nil)
    }
}

// MARK: - Provider

nonisolated struct RightNowProvider: TimelineProvider {
    func placeholder(in context: Context) -> RightNowEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (RightNowEntry) -> Void) {
        let snapshot = SharedStateFile.snapshot()
        let entry = RightNowEntry.make(snapshot, at: .now)
        completion(context.isPreview && entry.total == 0 ? .sample : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RightNowEntry>) -> Void) {
        let snapshot = SharedStateFile.snapshot()
        let now = Date.now
        let cal = PregnancyMath.calendar
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)

        // Every moment the card changes: dose times, window starts/ends, midnight.
        let today = snapshot.instances(on: now)
        var dates: Set<Date> = [now, midnight]
        for instance in today where instance.scheduledAt > now { dates.insert(instance.scheduledAt) }
        for window in MedsEngine.noFoodWindows(for: snapshot.carryOver(into: now) + today) {
            if window.start > now { dates.insert(window.start) }
            if window.end > now { dates.insert(window.end) }
        }

        let entries = dates.filter { $0 <= midnight }.sorted().map { RightNowEntry.make(snapshot, at: $0) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Widget

struct RightNowWidget: Widget {
    let kind = "BloomRightNow"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RightNowProvider()) { entry in
            RightNowWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetCanvas(glow: entry.window != nil ? Theme.coralSoft : Theme.peachSoft)
                }
        }
        .configurationDisplayName("Right now")
        .description("The dose that's due, your no-food countdown and today's progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct RightNowWidgetView: View {
    var entry: RightNowEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular: RightNowRectangular(entry: entry)
        case .accessoryCircular: RightNowCircular(entry: entry)
        case .accessoryInline: RightNowInline(entry: entry)
        case .systemMedium:
            HStack(spacing: 14) {
                RightNowMain(entry: entry)
                if entry.total > 0 {
                    Rectangle().fill(Theme.ringTrack).frame(width: 1).padding(.vertical, 4)
                    TodayList(entry: entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        default: RightNowMain(entry: entry)
        }
    }
}

// MARK: - Main card

private struct RightNowMain: View {
    var entry: RightNowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WidgetCaption(text: "Right now", color: entry.window != nil ? Theme.coralDeep : Theme.blushDeep)
                Spacer(minLength: 4)
                if entry.total > 0 {
                    ProgressRing(progress: Double(entry.resolved) / Double(entry.total), lineWidth: 4)
                        .frame(width: 22, height: 22)
                }
            }
            Spacer(minLength: 6)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if !entry.onboarded {
            message(emoji: "🌸", title: "Open Bloom", subtitle: "to get started")
        } else if let dose = entry.due.first {
            DueBlock(dose: dose, extra: entry.due.count - 1, window: entry.window)
        } else if let window = entry.window {
            NoFoodBlock(window: window, now: entry.date)
        } else if entry.allDone {
            message(emoji: "🌷", title: "All done", subtitle: "All logged today", tint: Theme.sageDeep)
        } else if let next = entry.next {
            NextBlock(next: next, nextWindow: entry.nextWindow)
        } else {
            message(emoji: "🍓", title: "Food OK", subtitle: "No doses today", tint: Theme.sageDeep)
        }
    }

    private func message(emoji: String, title: String, subtitle: String, tint: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emoji).font(.system(size: 30))
            Text(title)
                .font(.bloom(.title3, weight: .heavy))
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.bloom(.caption, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }
}

private struct DueBlock: View {
    var dose: DoseInstance
    var extra: Int
    var window: NoFoodWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                EmojiBlob(emoji: dose.medication.emoji, size: 34, fill: Theme.blushSoft)
                VStack(alignment: .leading, spacing: 0) {
                    Text(extra > 0 ? "Time for · +\(extra)" : "Time for")
                        .font(.bloom(.caption2, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(dose.medication.shortName)
                        .font(.bloom(.headline, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Button(intent: MarkDoseTakenIntent(medID: dose.medication.id.uuidString, scheduledAt: dose.scheduledAt)) {
                Label("Taken", systemImage: "checkmark")
                    .font(.bloom(.subheadline, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.blush, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NoFoodBlock: View {
    var window: NoFoodWindow
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No food")
                .font(.bloom(.subheadline, weight: .heavy))
                .foregroundStyle(Theme.coralDeep)
            Text(timerInterval: min(now, window.end)...window.end, countsDown: true)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Eat again at \(window.end.formatted(date: .omitted, time: .shortened))")
                .font(.bloom(.caption, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ProgressView(timerInterval: window.start...window.end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(Theme.coral)
                .padding(.top, 4)
        }
    }
}

private struct NextBlock: View {
    var next: DoseInstance
    var nextWindow: NoFoodWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetChip(text: "Food OK", symbol: "fork.knife", tint: Theme.sageDeep, fill: Theme.sageSoft)
            HStack(spacing: 8) {
                EmojiBlob(emoji: next.medication.emoji, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Next at \(next.scheduledAt.formatted(date: .omitted, time: .shortened))")
                        .font(.bloom(.caption2, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(next.medication.shortName)
                        .font(.bloom(.headline, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

// MARK: - Medium: today's list

private struct TodayList: View {
    var entry: RightNowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetCaption(text: "\(entry.resolved) of \(entry.total) today")
            ForEach(entry.today.prefix(4)) { dose in
                HStack(spacing: 7) {
                    statusIcon(dose)
                    Text(dose.medication.shortName)
                        .font(.bloom(.caption, weight: .bold))
                        .foregroundStyle(dose.isPending ? Theme.text : Theme.textSecondary)
                        .strikethrough(dose.isSkipped)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text((dose.log?.takenAt ?? dose.scheduledAt).formatted(date: .omitted, time: .shortened))
                        .font(.bloom(.caption2, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            if entry.today.count > 4 {
                Text("+\(entry.today.count - 4) more")
                    .font(.bloom(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func statusIcon(_ dose: DoseInstance) -> some View {
        if dose.isTaken {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sage)
        } else if dose.isSkipped {
            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.textSecondary.opacity(0.6))
        } else if dose.scheduledAt <= entry.date {
            Image(systemName: "circle.inset.filled").foregroundStyle(Theme.blush)
        } else {
            Image(systemName: "circle").foregroundStyle(Theme.ringTrack)
        }
    }
}

// MARK: - Lock Screen

private struct RightNowRectangular: View {
    var entry: RightNowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let dose = entry.due.first {
                Text("\(dose.medication.emoji) \(dose.medication.shortName)").font(.bloom(.headline, weight: .heavy)).lineLimit(1)
                Text("Due since \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))").font(.bloom(.caption))
            } else if let window = entry.window {
                Text("No food").font(.bloom(.headline, weight: .heavy))
                Text(timerInterval: min(entry.date, window.end)...window.end, countsDown: true)
                    .font(.bloom(.body, weight: .bold)).monospacedDigit()
            } else if let next = entry.next {
                Text("\(next.medication.emoji) \(next.medication.shortName)").font(.bloom(.headline, weight: .heavy)).lineLimit(1)
                Text("Next at \(next.scheduledAt.formatted(date: .omitted, time: .shortened))").font(.bloom(.caption))
            } else {
                Text("Bloom").font(.bloom(.headline, weight: .heavy))
                Text(entry.allDone ? "All doses logged 🌷" : "Food OK").font(.bloom(.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }
}

private struct RightNowCircular: View {
    var entry: RightNowEntry

    var body: some View {
        if let window = entry.window {
            ProgressView(timerInterval: window.start...window.end, countsDown: true) {
                Image(systemName: "fork.knife")
            }
            .progressViewStyle(.circular)
        } else {
            Gauge(value: Double(entry.resolved), in: 0...Double(max(entry.total, 1))) {
                Image(systemName: "pills.fill")
            } currentValueLabel: {
                Text(entry.total == 0 ? "–" : "\(entry.resolved)/\(entry.total)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
    }
}

private struct RightNowInline: View {
    var entry: RightNowEntry

    var body: some View {
        if let dose = entry.due.first {
            Text("\(dose.medication.emoji) Time for \(dose.medication.shortName)")
        } else if let window = entry.window {
            Text("No food until \(window.end.formatted(date: .omitted, time: .shortened))")
        } else if let next = entry.next {
            Text("\(next.medication.emoji) \(next.medication.shortName) at \(next.scheduledAt.formatted(date: .omitted, time: .shortened))")
        } else {
            Text(entry.allDone ? "🌷 All doses logged" : "🍓 Food OK")
        }
    }
}
