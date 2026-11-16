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
                .containerBackground(for: .widget) { DayWidgetBackground() }
                .widgetURL(CarryLink.meds)
        }
        .configurationDisplayName("Right now")
        .description("The dose that's due, your no-food countdown and today's list.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// The warm day canvas behind every home-screen widget.
struct DayWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { DayPalette(scheme: scheme).canvas }
}

struct RightNowWidgetView: View {
    var entry: RightNowEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = DayPalette(scheme: scheme)
        switch family {
        case .accessoryRectangular: RightNowRectangular(entry: entry)
        case .accessoryCircular: RightNowCircular(entry: entry)
        case .accessoryInline: RightNowInline(entry: entry)
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                RightNowMain(entry: entry, p: p)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.onboarded && entry.total > 0 {
                    Rectangle().fill(p.divider).frame(width: 1)
                    TodayList(entry: entry, p: p, limit: 4, actions: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .systemLarge: RightNowLarge(entry: entry, p: p)
        default: RightNowMain(entry: entry, p: p)
        }
    }
}

private func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

// MARK: - Main state (small, and the left half of medium)

private struct RightNowMain: View {
    var entry: RightNowEntry
    var p: DayPalette
    var showCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showCaption {
                Text("Right now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.secondary)
                Spacer(minLength: 6)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: showCaption ? .infinity : nil, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        if !entry.onboarded {
            message(title: "Open Carry", subtitle: "to get started")
        } else if let dose = entry.due.first {
            DueBlock(dose: dose, extra: entry.due.count - 1, p: p)
        } else if let window = entry.window {
            NoFoodBlock(window: window, now: entry.date, p: p)
        } else if entry.allDone {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(p.greenCheck)
                    .widgetAccentable()
                Text("All logged")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.text)
                Text("\(entry.resolved) of \(entry.total) today")
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondary)
            }
        } else if let next = entry.next {
            NextBlock(next: next, p: p)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                FoodOKChip(p: p)
                Text("No doses today")
                    .font(.system(size: 15))
                    .foregroundStyle(p.secondary)
            }
        }
    }

    private func message(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(p.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(p.secondary)
        }
    }
}

private struct FoodOKChip: View {
    var p: DayPalette
    var body: some View {
        HStack(spacing: 5) {
            WidgetDot(color: p.green, size: 7)
            Text("Food OK")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(p.greenText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(p.greenTint, in: .capsule)
    }
}

private struct DueBlock: View {
    var dose: DoseInstance
    var extra: Int
    var p: DayPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                WidgetDot(color: p.rose)
                Text(extra > 0 ? "Due \(clock(dose.scheduledAt)) · +\(extra)" : "Due \(clock(dose.scheduledAt))")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(p.secondary)
            }
            Text(dose.medication.shortName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(p.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            TakenButton(dose: dose, p: p, compact: false)
        }
    }
}

private struct TakenButton: View {
    var dose: DoseInstance
    var p: DayPalette
    var compact: Bool

    var body: some View {
        Button(intent: MarkDoseTakenIntent(medID: dose.medication.id.uuidString, scheduledAt: dose.scheduledAt)) {
            Text("Taken")
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(compact ? p.rose : .white)
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? 12 : 0)
                .padding(.vertical, compact ? 6 : 8)
                .background(compact ? p.roseTint : p.rose, in: .capsule)
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark \(dose.medication.shortName) taken")
    }
}

private struct NoFoodBlock: View {
    var window: NoFoodWindow
    var now: Date
    var p: DayPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                WidgetDot(color: p.terra)
                Text("No food")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(p.terraText)
            }
            Text(timerInterval: min(now, window.end)...window.end, countsDown: true)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(p.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("Eat at \(clock(window.end))")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(p.secondary)
            Spacer(minLength: 4)
            ProgressView(timerInterval: window.start...window.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(p.terra)
        }
    }
}

private struct NextBlock: View {
    var next: DoseInstance
    var p: DayPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FoodOKChip(p: p)
            Spacer(minLength: 2)
            Text("Next · \(clock(next.scheduledAt))")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(p.secondary)
            Text(next.medication.shortName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(p.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Today's list (medium, large)

private struct TodayList: View {
    var entry: RightNowEntry
    var p: DayPalette
    var limit: Int
    var actions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: actions ? 0 : 7) {
            if !actions {
                Text("Today · \(entry.resolved) of \(entry.total)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.secondary)
            }
            let rows = Array(entry.today.prefix(limit))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, dose in
                if actions {
                    largeRow(dose)
                    if index < rows.count - 1 { Rectangle().fill(p.divider).frame(height: 1) }
                } else {
                    smallRow(dose)
                }
            }
            if entry.today.count > limit {
                Text("+\(entry.today.count - limit) more")
                    .font(.system(size: 13))
                    .foregroundStyle(p.muted)
                    .padding(.top, actions ? 6 : 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func smallRow(_ dose: DoseInstance) -> some View {
        HStack(spacing: 7) {
            Text(clock(dose.scheduledAt))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(p.secondary)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            WidgetDot(color: dotColor(dose), size: 7)
            Text(dose.medication.shortName)
                .font(.system(size: 13, weight: dose.isPending ? .medium : .regular))
                .foregroundStyle(dose.isPending ? p.text : p.muted)
                .strikethrough(dose.isSkipped)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func largeRow(_ dose: DoseInstance) -> some View {
        HStack(spacing: 10) {
            Text(clock(dose.scheduledAt))
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(p.secondary)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            WidgetDot(color: dotColor(dose))
            Text(dose.medication.shortName)
                .font(.system(size: 15, weight: dose.isPending ? .medium : .regular))
                .foregroundStyle(dose.isPending ? p.text : p.muted)
                .strikethrough(dose.isSkipped)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 6)
            trailing(dose)
        }
        .frame(minHeight: 38)
    }

    @ViewBuilder private func trailing(_ dose: DoseInstance) -> some View {
        if dose.isTaken {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(p.greenCheck)
                .widgetAccentable()
        } else if dose.isSkipped {
            Text("Skipped").font(.system(size: 13)).foregroundStyle(p.muted)
        } else if dose.scheduledAt <= entry.date {
            TakenButton(dose: dose, p: p, compact: true)
        } else {
            Circle().stroke(p.neutral, lineWidth: 1.5).frame(width: 20, height: 20)
        }
    }

    private func dotColor(_ dose: DoseInstance) -> Color {
        if dose.isTaken { return p.green }
        if dose.isSkipped { return p.neutral }
        return dose.scheduledAt <= entry.date ? p.rose : p.neutral
    }
}

// MARK: - Large

private struct RightNowLarge: View {
    var entry: RightNowEntry
    var p: DayPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Right now")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                if entry.total > 0 {
                    Text("\(entry.resolved) of \(entry.total) today")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(p.secondary)
                }
            }
            if entry.total > 0 {
                WidgetBar(progress: Double(entry.resolved) / Double(entry.total), fill: p.green, track: p.divider)
            }
            RightNowMain(entry: entry, p: p, showCaption: false)
                .frame(height: 112, alignment: .topLeading)
                .padding(14)
                .background(statusFill, in: .rect(cornerRadius: 20))
            if entry.onboarded && entry.total > 0 {
                TodayList(entry: entry, p: p, limit: 6, actions: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(p.card, in: .rect(cornerRadius: 20))
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var statusFill: Color {
        if entry.due.first != nil { return p.card }
        if entry.window != nil { return p.terraTint }
        return p.card
    }
}

// MARK: - Lock Screen

private struct RightNowRectangular: View {
    var entry: RightNowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !entry.onboarded {
                Text("Carry").font(.headline)
                Text("Open Carry to get started").font(.caption)
            } else if let dose = entry.due.first {
                Text(dose.medication.shortName).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                Text("Due \(clock(dose.scheduledAt))").font(.caption).monospacedDigit()
                progress
            } else if let window = entry.window {
                Text("No food").font(.headline)
                HStack(spacing: 4) {
                    Text(timerInterval: min(entry.date, window.end)...window.end, countsDown: true)
                        .monospacedDigit()
                        .frame(maxWidth: 64, alignment: .leading)
                    Text("· eat at \(clock(window.end))")
                }
                .font(.caption)
                progress
            } else if let next = entry.next {
                Text(next.medication.shortName).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                Text("Next · \(clock(next.scheduledAt))").font(.caption).monospacedDigit()
                progress
            } else {
                Text(entry.allDone ? "All logged" : "Food OK").font(.headline)
                progress
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }

    @ViewBuilder private var progress: some View {
        if entry.total > 0 {
            Text("\(entry.resolved) of \(entry.total) today").font(.caption).foregroundStyle(.secondary)
        }
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
            Text("Time for \(dose.medication.shortName)")
        } else if let window = entry.window {
            Text("No food until \(clock(window.end))")
        } else if let next = entry.next {
            Text("Next: \(next.medication.shortName) at \(clock(next.scheduledAt))")
        } else {
            Text(entry.allDone ? "All doses logged" : "Food OK")
        }
    }
}
