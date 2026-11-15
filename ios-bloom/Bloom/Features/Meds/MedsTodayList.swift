import SwiftUI

/// The day as one time-ordered list: medications (with a checkmark), "8:00–8:30 · No food" rows and meals.
/// Plain rows, no decoration.
struct MedsTodayList: View {
    var instances: [DoseInstance]
    var meals: [ScheduleMeal]
    var day: Date
    /// Future days are read-only.
    var canLog: Bool
    /// Today only: draws the now line and projects overdue food windows from now.
    var now: Date?
    var actions: DoseActions

    fileprivate enum Entry: Identifiable {
        case dose(DoseInstance)
        case noFood(NoFoodWindow)
        case meal(ScheduleMeal, start: Date, end: Date)
        case now(Date)

        var id: String {
            switch self {
            case .dose(let i): "dose-\(i.id)"
            case .noFood(let w): "nofood-\(Int(w.start.timeIntervalSince1970))"
            case .meal(let m, _, _): "meal-\(m.id)"
            case .now: "now"
            }
        }

        var time: Date {
            switch self {
            case .dose(let i): i.anchor
            case .noFood(let w): w.start
            case .meal(_, let start, _): start
            case .now(let d): d
            }
        }

        /// Ties: the food window opens before the dose that causes it, meals after doses.
        var rank: Int {
            switch self {
            case .noFood: 0
            case .now: 1
            case .dose: 2
            case .meal: 3
            }
        }
    }

    private var entries: [Entry] {
        var list: [Entry] = instances.map { .dose($0) }
        list += MedsEngine.noFoodWindows(for: instances, now: now).map { .noFood($0) }
        list += meals.map { meal in
            let start = meal.time.date(on: day)
            return .meal(meal, start: start, end: start.addingTimeInterval(Double(meal.durationMinutes) * 60))
        }
        list.sort { ($0.time, $0.rank) < ($1.time, $1.rank) }
        if let now, !list.isEmpty, let first = list.first?.time, let last = list.last?.time, now > first, now < last {
            list.append(.now(now))
            list.sort { ($0.time, $0.rank) < ($1.time, $1.rank) }
        }
        return list
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Nothing planned on this day.")
                    .font(.bloom(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0, !isNow(entry), !isNow(entries[index - 1]) {
                    Divider().padding(.leading, 88)
                }
                row(entry)
                    .transition(.opacity)
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.85),
                   value: instances.map { "\($0.id)\($0.anchor.timeIntervalSince1970)\($0.status?.rawValue ?? "")" })
    }

    private func isNow(_ entry: Entry) -> Bool {
        if case .now = entry { return true }
        return false
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .dose(let instance):
            TodayDoseRow(instance: instance, canLog: canLog, actions: actions)
        case .noFood(let window):
            SpanRow(start: window.start, end: window.end, title: "No food",
                    detail: window.reasons.joined(separator: ", "), tint: Theme.coralDeep, bar: Theme.coral)
                .accessibilityIdentifier("today-nofood")
        case .meal(let meal, let start, let end):
            SpanRow(start: start, end: end, title: meal.name, detail: "Food OK", tint: Theme.sageDeep, bar: Theme.sage)
                .accessibilityIdentifier("today-meal-\(meal.name)")
        case .now(let date):
            NowLine(date: date)
        }
    }
}

// MARK: - Rows

private let timeWidth: CGFloat = 72

private func clock(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// "8:00–8:30 · No food" / "12:30–13:00 · Lunch"
private struct SpanRow: View {
    var start: Date
    var end: Date
    var title: String
    var detail: String
    var tint: Color
    var bar: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(clock(start))
                Text(clock(end))
            }
            .font(.bloom(.caption))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: timeWidth, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(bar)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.bloom(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(clock(start)) to \(clock(end))")
    }
}

private struct TodayDoseRow: View {
    var instance: DoseInstance
    var canLog: Bool
    var actions: DoseActions
    @Environment(AppStore.self) private var store

    var body: some View {
        let med = instance.medication
        HStack(spacing: 12) {
            Text(clock(instance.anchor))
                .font(.bloom(.subheadline))
                .monospacedDigit()
                .foregroundStyle(instance.isPending ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: timeWidth, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(instance.isTaken ? Theme.sage : (instance.isSkipped ? Color(uiColor: .systemGray3) : Theme.blush))
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(med.shortName)
                    .font(.bloom(.body, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .strikethrough(instance.isSkipped, color: Theme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(statusText)
                    .font(.bloom(.footnote))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)

            if canLog {
                Button {
                    if instance.isPending { actions.taken(instance) } else { actions.undo(instance) }
                } label: {
                    Image(systemName: instance.isTaken ? "checkmark.circle.fill" : (instance.isSkipped ? "minus.circle.fill" : "circle"))
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(instance.isTaken ? Theme.sageDeep : (instance.isSkipped ? Theme.textSecondary : Theme.blushDeep))
                        .symbolEffect(.bounce, value: instance.isTaken)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(instance.isPending ? "Mark \(med.shortName) taken" : "Undo \(med.shortName)")
                .accessibilityIdentifier("today-check-\(med.shortName)")
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, canLog ? 6 : 14)
        .contentShape(.rect)
        .contextMenu {
            if canLog { DoseMenuItems(instance: instance, actions: actions) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-row-\(med.shortName)")
    }

    private var statusText: String {
        let planned = clock(instance.scheduledAt)
        var parts: [String] = []
        if instance.isTaken, let takenAt = instance.log?.takenAt {
            let taken = clock(takenAt)
            parts.append(taken == planned ? "Taken" : "Taken \(taken) · planned \(planned)")
        } else if instance.isSkipped {
            parts.append("Skipped · planned \(planned)")
        } else {
            if let dose = store.detailLine(instance.medication) { parts.append(dose) }
            parts.append(instance.medication.foodSummary)
        }
        if !instance.isPending, let by = store.loggedByLine(instance.log) { parts.append(by) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if instance.isTaken { return Theme.sageDeep }
        if instance.isSkipped { return Theme.textSecondary }
        return instance.medication.foodRule == .emptyStomach ? Theme.coralDeep : Theme.textSecondary
    }
}

private struct NowLine: View {
    var date: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("Now")
                .font(.bloom(.caption, weight: .semibold))
                .foregroundStyle(Theme.blushDeep)
                .frame(width: timeWidth, alignment: .trailing)
            Circle().fill(Theme.blushDeep).frame(width: 7, height: 7)
            Rectangle().fill(Theme.blushDeep).frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .accessibilityLabel("Now, \(clock(date))")
    }
}
