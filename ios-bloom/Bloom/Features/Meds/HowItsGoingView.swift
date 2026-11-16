import SwiftUI

/// Board 10: How it's going. Counts from her own logs, a 7-day bar chart, up to three plain facts.
/// A record, never a score.
struct HowItsGoingView: View {
    var owner: MedOwner
    /// "Move it later?" opens Meds & routines.
    var onMoveLater: (Medication?) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let today = store.instances(owner, on: PregnancyMath.calendar.startOfDay(for: store.now))
        let done = today.filter { !$0.isPending }.count
        let week = store.weekCounts(owner)
        let streak = store.streak(owner)
        let days = store.lastDays(owner, count: 7)
        let notes = store.observations(owner)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("How it's going")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.dayText)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { tiles(done: done, total: today.count, week: week, streak: streak) }
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                tile("Today", "\(done) of \(today.count)", "\(max(0, today.count - done)) to go")
                                tile("This week", "\(week.logged) of \(week.planned)", "\(week.onTime) on time")
                            }
                            tile("Streak", streak.current == 1 ? "1 day" : "\(streak.current) days", "best \(streak.best)", green: true)
                        }
                    }
                    chart(days)
                    if !notes.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                if index > 0 { DayDivider() }
                                observation(note)
                            }
                        }
                        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
                    }
                    Text("A record for you and your care team, not a score.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dayMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.dayCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(Theme.rose)
                        .accessibilityIdentifier("progress-done")
                }
            }
        }
        .presentationBackground(Theme.dayCanvas)
    }

    @ViewBuilder
    private func tiles(done: Int, total: Int, week: (logged: Int, planned: Int, onTime: Int), streak: (current: Int, best: Int)) -> some View {
        tile("Today", "\(done) of \(total)", "\(max(0, total - done)) to go")
        tile("This week", "\(week.logged) of \(week.planned)", "\(week.onTime) on time")
        tile("Streak", streak.current == 1 ? "1 day" : "\(streak.current) days", "best \(streak.best)", green: true)
    }

    private func tile(_ label: String, _ value: String, _ caption: String, green: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(green ? Theme.greenText : Theme.dayMuted)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(green ? Theme.greenText : Theme.dayText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(green ? Theme.greenText.opacity(0.85) : Theme.daySecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: 104)
        .background(green ? Theme.greenTint : Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func chart(_ days: [[DoseInstance]]) -> some View {
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: store.now)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Last 7 days")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.dayText)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, list in
                    let day = PregnancyMath.addDays(index - (days.count - 1), to: today)
                    let isToday = index == days.count - 1
                    let fraction = list.isEmpty ? 0 : CGFloat(list.filter { !$0.isPending }.count) / CGFloat(list.count)
                    VStack(spacing: 8) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Theme.dayDivider)
                            Capsule()
                                .fill(isToday ? Theme.rose : Theme.greenDot)
                                .frame(height: max(fraction > 0 ? 8 : 0, 110 * fraction))
                        }
                        .frame(height: 110)
                        Text(String(day.formatted(.dateTime.weekday(.narrow))))
                            .font(.system(size: 13, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? Theme.rose : Theme.dayMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))): \(list.filter { !$0.isPending }.count) of \(list.count) logged")
                }
            }
        }
        .padding(16)
        .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
    }

    private func observation(_ note: ProgressObservation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dot(note.kind))
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.dayText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note.detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.daySecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .late(let id) = note.kind {
                    Button("Move it later?") {
                        Haptics.tap()
                        onMoveLater(store.medications.first { $0.id == id })
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.rose)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("progress-move-later")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func dot(_ kind: ProgressObservation.Kind) -> Color {
        switch kind {
        case .onTime: Theme.greenDot
        case .late: Theme.terraDot
        case .unlogged: Theme.neutralDot
        }
    }
}
