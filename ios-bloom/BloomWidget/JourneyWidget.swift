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
                .containerBackground(for: .widget) { DayWidgetBackground() }
        }
        .configurationDisplayName("Journey")
        .description("This week's baby size and how many days to go.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct JourneyWidgetView: View {
    var entry: JourneyEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var p: DayPalette { DayPalette(scheme: scheme) }

    var body: some View {
        // Tracking paused: no week, baby or days to go — a quiet meds-only card instead.
        if entry.profile?.trackingPaused == true {
            pausedView
        } else if let age = entry.age, let profile = entry.profile {
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
                    Text("Week \(age.weeks)").font(.headline)
                    Text(daysToGoText(age)).font(.caption)
                    Gauge(value: min(age.ringProgress, 1)) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                }
                .widgetAccentable()
            case .accessoryInline:
                Text("Week \(age.weeks) · \(daysToGoText(age))")
            default: small(age: age)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Carry")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.text)
                Text("to start your journey")
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    @ViewBuilder
    private var pausedView: some View {
        switch family {
        case .accessoryInline:
            Text("Meds keep working")
        default:
            VStack(alignment: .leading, spacing: 5) {
                CarryMark(size: family == .systemMedium ? 44 : 36, progress: 1, dotScale: 0.5, dotOffset: 0.19,
                          arcColor: p.rose, dotColor: p.terra, trackColor: p.roseTint)
                Spacer(minLength: 4)
                Text("Pregnancy tracking paused")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(p.text)
                Text("Medications keep working")
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func ring(age: GestationalAge, size: CGFloat) -> some View {
        // The Carry arc as progress (week / 40); the dot grows each trimester.
        ZStack {
            CarryMark(size: size, progress: min(1, age.ringProgress),
                      dotScale: [0.42, 0.56, 0.7][max(0, min(2, age.trimester - 1))], dotOffset: 0.19,
                      arcColor: p.rose, dotColor: p.terra, trackColor: p.roseTint)
            Text("\(age.weeks)")
                .font(.system(size: size * 0.27, weight: .semibold, design: .serif))
                .monospacedDigit()
                .foregroundStyle(p.text)
                .minimumScaleFactor(0.7)
                .offset(x: -size * 0.09)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Week \(age.weeks)")
    }

    private func small(age: GestationalAge) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ring(age: age, size: 78)
            Spacer(minLength: 6)
            Text("Week \(age.weeks)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(p.text)
            Text(daysToGoText(age))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(p.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(age: GestationalAge, profile: PregnancyProfile) -> some View {
        HStack(spacing: 16) {
            ring(age: age, size: 112)
            VStack(alignment: .leading, spacing: 3) {
                Text(age.trimesterTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.secondary)
                Text(age.headline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if let week = entry.week {
                    Text("\(profile.babyName) is \(week.sizeSentence)")
                        .font(.system(size: 13))
                        .foregroundStyle(p.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 2)
                Text(daysToGoText(age))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(p.rose)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(p.roseTint, in: .capsule)
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
