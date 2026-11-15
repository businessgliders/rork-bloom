import SwiftUI

/// The big "Right now" card: can I eat, what's due, what's next. Ticks every second.
struct RightNowCard: View {
    var instances: [DoseInstance]
    /// Yesterday's taken doses whose no-food window may still be running.
    var carryOver: [DoseInstance] = []
    var onTaken: (DoseInstance) -> Void
    var onSkip: (DoseInstance) -> Void
    var onTakenAt: (DoseInstance) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = MedsEngine.rightNow(instances: instances, now: context.date, carryOver: carryOver)
            VStack(alignment: .leading, spacing: 0) {
                FoodStatusBand(food: state.food, now: context.date, onTaken: onTaken)
                VStack(alignment: .leading, spacing: 16) {
                    if let due = state.due.first {
                        DueDoseView(instance: due, extraDue: state.due.count - 1, now: context.date,
                                    onTaken: onTaken, onSkip: onSkip, onTakenAt: onTakenAt)
                    } else if let next = state.next {
                        NextDoseView(instance: next, now: context.date)
                    } else if state.allDone {
                        allDoneView
                    } else {
                        Text("Nothing planned today.")
                            .font(.bloom(.headline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    progressFooter(state)
                }
                .padding(20)
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: state.due.map(\.id))
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: foodKey(state.food))
        }
    }

    private var allDoneView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.sageDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("All done for today")
                    .font(.bloom(.title3, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Every dose is logged.")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func progressFooter(_ state: RightNowState) -> some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ringTrack)
                    Capsule()
                        .fill(Theme.sageDeep)
                        .frame(width: state.totalToday == 0 ? 0 : proxy.size.width * CGFloat(state.resolvedToday) / CGFloat(state.totalToday))
                }
            }
            .frame(height: 6)
            Text("\(state.resolvedToday) of \(state.totalToday) logged")
                .font(.bloom(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func foodKey(_ food: RightNowState.Food) -> String {
        switch food {
        case .noFood(let w): "no-\(w.start.timeIntervalSince1970)-\(w.end.timeIntervalSince1970)"
        case .foodOK(let next): "ok-\(next?.start.timeIntervalSince1970 ?? 0)"
        case .holdForDose(let instance, _, _): "hold-\(instance.id)"
        }
    }
}

// MARK: - Food status

private struct FoodStatusBand: View {
    @Environment(\.medsPerson) private var person
    var food: RightNowState.Food
    var now: Date
    var onTaken: (DoseInstance) -> Void

    var body: some View {
        switch food {
        case .holdForDose(let instance, let emptySince, let delaysTo):
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    icon("hourglass", tint: Theme.coral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Eating now delays \(instance.medication.shortName) to \(delaysTo.formatted(date: .omitted, time: .shortened))")
                            .font(.bloom(.title3, weight: .semibold))
                            .foregroundStyle(Theme.coralDeep)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.numericText())
                        Text("It needs \(Medication.durationText(instance.medication.noFoodBeforeMinutes)) without food first.")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    onTaken(instance)
                } label: {
                    Label("Haven't eaten since \(emptySince.formatted(date: .omitted, time: .shortened))? Take it now", systemImage: "checkmark")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.coralDeep, fill: Theme.surface.opacity(0.85)))
                .accessibilityIdentifier("take-now-empty")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.coralSoft)


        case .noFood(let window):
            let total = window.end.timeIntervalSince(window.start)
            let elapsed = now.timeIntervalSince(window.start)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    icon("hand.raised.fill", tint: Theme.coral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No food until \(window.end.formatted(date: .omitted, time: .shortened))")
                            .font(.bloom(.title3, weight: .semibold))
                            .foregroundStyle(Theme.coralDeep)
                            .contentTransition(.numericText())
                        Text("\(remainingText(window.end.timeIntervalSince(now))) left · for \(window.reasons.joined(separator: " & "))")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                        if !window.isConfirmed {
                            Text("Planned pause · starts counting when \(PersonWording.takes(person)) it")
                                .font(.bloom(.caption, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ringTrack)
                        Capsule()
                            .fill(Theme.coral)
                            .frame(width: proxy.size.width * CGFloat(min(max(elapsed / max(total, 1), 0), 1)))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.coralSoft)
            .accessibilityElement(children: .combine)

        case .foodOK(let next):
            HStack(alignment: .top, spacing: 14) {
                icon("fork.knife", tint: Theme.sage)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Food OK")
                        .font(.bloom(.title3, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                    if let next {
                        Text("Next snack pause at \(next.start.formatted(date: .omitted, time: .shortened)) · in \(remainingText(next.start.timeIntervalSince(now)))")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                    } else {
                        Text("No food pauses left today")
                            .font(.bloom(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sageSoft)
            .accessibilityElement(children: .combine)
        }
    }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(tint, in: .circle)
    }
}

/// "1 h 05 min" / "23 min" / "45 s" style countdown text.
func remainingText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.up)))
    if seconds < 60 { return "\(seconds) s" }
    let minutes = Int((Double(seconds) / 60).rounded(.up))
    if minutes < 60 { return "\(minutes) min" }
    let h = minutes / 60
    let m = minutes % 60
    return m == 0 ? "\(h) h" : "\(h) h \(String(format: "%02d", m)) min"
}

// MARK: - Due / next

private struct DueDoseView: View {
    @Environment(\.medsPerson) private var person
    var instance: DoseInstance
    var extraDue: Int
    var now: Date
    var onTaken: (DoseInstance) -> Void
    var onSkip: (DoseInstance) -> Void
    var onTakenAt: (DoseInstance) -> Void

    var body: some View {
        let med = instance.medication
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                MedBadge(medication: med, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Time for \(med.shortName)")
                        .font(.bloom(.title3, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.blushDeep)
                    Text(ruleLine(med))
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    onTaken(instance)
                } label: {
                    Label("Taken", systemImage: "checkmark")
                }
                .buttonStyle(BloomPrimaryButtonStyle())

                Button {
                    onSkip(instance)
                } label: {
                    Text("Skip")
                        .frame(minWidth: 64)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BloomSoftButtonStyle())
            }

            HStack {
                Button {
                    onTakenAt(instance)
                } label: {
                    Text("Took it at a different time")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.blushDeep)
                }
                Spacer()
                if extraDue > 0 {
                    Text("+\(extraDue) more due")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var subtitle: String {
        let planned = instance.scheduledAt.formatted(date: .omitted, time: .shortened)
        let dose = instance.medication.dose.trimmingCharacters(in: .whitespaces)
        let late = Int(now.timeIntervalSince(instance.scheduledAt) / 60)
        var parts: [String] = []
        if !dose.isEmpty { parts.append(dose) }
        parts.append(late >= 2 ? "planned \(planned) · \(Medication.durationText(late)) ago" : "planned \(planned)")
        return parts.joined(separator: " · ")
    }

    private func ruleLine(_ med: Medication) -> String {
        switch med.foodRule {
        case .emptyStomach:
            return med.noFoodAfterMinutes > 0
                ? "Then no food for \(Medication.durationText(med.noFoodAfterMinutes)), counted from when \(PersonWording.takes(person)) it"
                : "Take on an empty stomach"
        case .withFood: return "Take with food"
        case .any: return "With or without food"
        }
    }
}

private struct NextDoseView: View {
    var instance: DoseInstance
    var now: Date

    var body: some View {
        let med = instance.medication
        HStack(spacing: 14) {
            MedBadge(medication: med, size: 44, fill: Theme.surfaceMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next: \(med.reasonLabel)")
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(instance.scheduledAt.formatted(date: .omitted, time: .shortened)) · in \(remainingText(instance.scheduledAt.timeIntervalSince(now)))")
                    .font(.bloom(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.peachDeep)
                    .monospacedDigit()
                Text(med.foodSummary)
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Other days

/// Shown instead of the Right now card when browsing another day.
struct DaySummaryCard: View {
    var day: Date
    var instances: [DoseInstance]
    var isFuture: Bool

    var body: some View {
        let resolved = instances.filter { !$0.isPending }.count
        let taken = instances.filter(\.isTaken).count
        HStack(spacing: 18) {
            ZStack {
                ProgressRing(progress: instances.isEmpty ? 0 : Double(resolved) / Double(instances.count), lineWidth: 6)
                Text(instances.isEmpty ? "–" : "\(resolved)/\(instances.count)")
                    .font(.bloom(.subheadline, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.bloom(.title3, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if instances.isEmpty {
                    Text("No doses planned")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                } else if isFuture {
                    Text("\(instances.count) doses planned · you can log them on the day")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(taken) taken · \(resolved - taken) skipped · \(instances.count - resolved) not logged")
                        .font(.bloom(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                    if resolved < instances.count {
                        Text("Tap a dose below to log it late")
                            .font(.bloom(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.blushDeep)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .bloomCard()
    }
}
