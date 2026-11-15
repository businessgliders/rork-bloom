import SwiftUI
import WidgetKit

nonisolated struct JourneyEntry: TimelineEntry {
    let date: Date
    let profile: PregnancyProfile?

    var age: GestationalAge? { profile?.progress(on: date) }
    var week: WeekContent? { age.flatMap { WeekLibrary.week($0.contentWeek) } }

    static var sample: JourneyEntry {
        let due = PregnancyMath.addDays(126, to: .now)
        let profile = PregnancyProfile(
            momName: "Anna", partnerName: "", babyNickname: "Bean",
            datingMethod: .dueDate, datingDate: due, embryoAgeDays: 5, dueDate: due
        )
        return JourneyEntry(date: .now, profile: profile)
    }
}

nonisolated struct JourneyProvider: TimelineProvider {
    func placeholder(in context: Context) -> JourneyEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (JourneyEntry) -> Void) {
        let profile = SharedStateFile.snapshot().profile
        completion(profile == nil && context.isPreview ? .sample : JourneyEntry(date: .now, profile: profile))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JourneyEntry>) -> Void) {
        let profile = SharedStateFile.snapshot().profile
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: .now)
        // A new entry each midnight for a week; the app reloads sooner whenever dates change.
        var entries = [JourneyEntry(date: .now, profile: profile)]
        for offset in 1...7 {
            if let day = cal.date(byAdding: .day, value: offset, to: today) {
                entries.append(JourneyEntry(date: day, profile: profile))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct JourneyWidget: Widget {
    let kind = "BloomJourney"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JourneyProvider()) { entry in
            JourneyWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetCanvas() }
        }
        .configurationDisplayName("Journey")
        .description("This week's baby size and how many days to go.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct JourneyWidgetView: View {
    var entry: JourneyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let age = entry.age, let profile = entry.profile {
            switch family {
            case .systemMedium: medium(age: age, profile: profile)
            case .accessoryCircular:
                Gauge(value: min(age.ringProgress, 1)) {
                    Text("wk")
                } currentValueLabel: {
                    Text("\(age.weeks)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Week \(age.weeks)").font(.bloom(.headline, weight: .semibold))
                    Text(daysToGoText(age)).font(.bloom(.caption))
                    Gauge(value: min(age.ringProgress, 1)) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                }
                .widgetAccentable()
            case .accessoryInline:
                Text("Week \(age.weeks) · \(daysToGoText(age))")
            default: small(age: age)
            }
        } else {
            VStack(spacing: 6) {
                StatusIcon(symbol: "calendar", size: 34, tint: Theme.blush)
                Text("Open Bloom to start your journey")
                    .font(.bloom(.caption, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func ring(age: GestationalAge, size: CGFloat) -> some View {
        ZStack {
            ProgressRing(progress: age.ringProgress, lineWidth: size * 0.08)
            VStack(spacing: -2) {
                Text("\(age.weeks)")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(age.weeks == 1 ? "week" : "weeks")
                    .font(.system(size: size * 0.12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }

    private func small(age: GestationalAge) -> some View {
        VStack(spacing: 6) {
            ring(age: age, size: 84)
            VStack(spacing: 0) {
                Text(entry.week?.sizeLabel ?? "Week \(age.weeks)")
                    .font(.bloom(.caption, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(daysToGoText(age))
                    .font(.bloom(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.blushDeep)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func medium(age: GestationalAge, profile: PregnancyProfile) -> some View {
        HStack(spacing: 16) {
            ring(age: age, size: 118)
            VStack(alignment: .leading, spacing: 4) {
                WidgetCaption(text: age.trimesterTitle, color: Theme.sageDeep)
                Text(age.headline)
                    .font(.bloom(.title3, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let week = entry.week {
                    Text(week.sizeLabel)
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
                Text(daysToGoText(age))
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.blushDeep)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func daysToGoText(_ age: GestationalAge) -> String {
        switch age.daysToGo {
        case ..<0: return "Baby time!"
        case 0: return "Due today"
        case 1: return "1 day to go"
        default: return "\(age.daysToGo) days to go"
        }
    }
}
