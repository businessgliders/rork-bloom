import Foundation

/// A stretch of time with no food: the part before one medication, the part after it,
/// or one block where different medications' windows overlap.
nonisolated struct NoFoodWindow: Equatable, Identifiable {
    enum Part: String, Equatable {
        /// Before the dose, ending at its time.
        case before
        /// After the dose, counted from when it was taken (or its planned time until then).
        case after
        /// Two or more medications' windows that overlap, shown as one.
        case combined
    }

    var start: Date
    var end: Date
    /// Medication names that cause this window.
    var reasons: [String]
    /// True when at least one dose inside has actually been taken (window is real, not just planned).
    var isConfirmed: Bool
    var part: Part = .combined

    var id: String { "\(part.rawValue)-\(reasons.joined(separator: "+"))-\(Int(start.timeIntervalSince1970))" }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// "before Iron", "after Iron", "Iron & Thyroid".
    var label: String {
        let names = reasons.joined(separator: " & ")
        switch part {
        case .before: return "before \(names)"
        case .after: return "after \(names)"
        case .combined: return names
        }
    }

    /// "No food · before Iron".
    var title: String { "No food · \(label)" }
}

/// One row on the Meds timeline.
nonisolated enum MedsTimelineEntry: Identifiable, Equatable {
    case dose(DoseInstance)
    case noFood(NoFoodWindow)
    case foodOK(start: Date, until: Date?)

    var id: String {
        switch self {
        case .dose(let instance): "dose-\(instance.id)"
        case .noFood(let window): "nofood-\(window.id)"
        case .foodOK(let start, _): "foodok-\(Int(start.timeIntervalSince1970))"
        }
    }

    /// Where the entry sits on the day's axis.
    var time: Date {
        switch self {
        case .dose(let instance): instance.anchor
        case .noFood(let window): window.start
        case .foodOK(let start, _): start
        }
    }

    /// Ties at the same minute: window ends/starts read before the dose.
    fileprivate var sortRank: Int {
        switch self {
        case .foodOK: 0
        case .noFood: 1
        case .dose: 2
        }
    }
}

/// What the Right now card should say.
nonisolated struct RightNowState: Equatable {
    enum Food: Equatable {
        /// Inside a no-food window.
        case noFood(NoFoodWindow)
        /// Free to eat; `nextWindow` is the next planned pause today, if any.
        case foodOK(nextWindow: NoFoodWindow?)
        /// A due dose needs an empty stomach first. Eating now would push it to `eatingDelaysTo`;
        /// if she hasn't eaten since `emptySince`, she can take it right away.
        case holdForDose(DoseInstance, emptySince: Date, eatingDelaysTo: Date)
    }

    var food: Food
    /// Pending doses whose time has come (earliest first).
    var due: [DoseInstance]
    /// The next pending dose later today.
    var next: DoseInstance?
    var totalToday: Int
    var resolvedToday: Int

    var allDone: Bool { totalToday > 0 && resolvedToday == totalToday }
}

/// Pure scheduling logic. Everything here is deterministic for a given input so it is easy to reason about.
nonisolated enum MedsEngine {
    static var calendar: Calendar { PregnancyMath.calendar }

    // MARK: Instances

    static func instances(on day: Date, medications: [Medication], logs: [DoseLog]) -> [DoseInstance] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayLogs = logs.filter { $0.scheduledAt >= dayStart && $0.scheduledAt < dayEnd }

        var result: [DoseInstance] = []
        var usedLogs = Set<UUID>()

        for med in medications where med.isActive(on: dayStart) {
            let times = med.plannedTimes(on: dayStart)
            for time in times {
                let scheduled = time.date(on: dayStart)
                var log = dayLogs.first { $0.medicationID == med.id && abs($0.scheduledAt.timeIntervalSince(scheduled)) < 30 && !usedLogs.contains($0.id) }
                // One planned dose a day: a log made before the plan moved still belongs to it.
                if log == nil, med.managed, times.count == 1 {
                    log = dayLogs.first { $0.medicationID == med.id && !usedLogs.contains($0.id) }
                }
                if let log { usedLogs.insert(log.id) }
                // Keep the logged plan time so undo and sync find the same dose.
                result.append(DoseInstance(medication: med, scheduledAt: log?.scheduledAt ?? scheduled, log: log))
            }
        }

        // Logs whose planned time no longer exists (the schedule was edited later) still show as history.
        for log in dayLogs where !usedLogs.contains(log.id) {
            if let med = medications.first(where: { $0.id == log.medicationID }) {
                result.append(DoseInstance(medication: med, scheduledAt: log.scheduledAt, log: log))
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt { return lhs.scheduledAt < rhs.scheduledAt }
            return Medication.sameTimeOrder(lhs.medication, rhs.medication)
        }
    }

    // MARK: Food windows

    /// No-food windows for the given doses. Each dose gives a "before" part ending at its time and
    /// an "after" part starting at it, so the medication sits between them in the list.
    /// Each window counts from the dose's anchor: the actual taken time once logged, otherwise the planned time.
    /// Windows merge only where different medications' windows overlap (touching isn't overlapping).
    /// Skipped doses create no window.
    /// When `now` is given, an overdue dose that hasn't been logged projects its window from `now`
    /// ("if you take it now"), so the app never claims a pause that started without the medicine.
    static func noFoodWindows(for instances: [DoseInstance], now: Date? = nil) -> [NoFoodWindow] {
        var raw: [NoFoodWindow] = []
        for instance in instances {
            let med = instance.medication
            guard med.hasNoFoodWindow, !instance.isSkipped else { continue }
            var anchor = instance.anchor
            if let now, instance.isPending, instance.scheduledAt < now { anchor = now }
            if med.noFoodBeforeMinutes > 0 {
                raw.append(NoFoodWindow(start: anchor.addingTimeInterval(-Double(med.noFoodBeforeMinutes) * 60), end: anchor,
                                        reasons: [med.reasonLabel], isConfirmed: instance.isTaken, part: .before))
            }
            if med.noFoodAfterMinutes > 0 {
                raw.append(NoFoodWindow(start: anchor, end: anchor.addingTimeInterval(Double(med.noFoodAfterMinutes) * 60),
                                        reasons: [med.reasonLabel], isConfirmed: instance.isTaken, part: .after))
            }
        }
        raw.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        var merged: [NoFoodWindow] = []
        for window in raw {
            if var last = merged.last, window.start < last.end, !Set(window.reasons).isSubset(of: last.reasons) {
                last.end = max(last.end, window.end)
                for reason in window.reasons where !last.reasons.contains(reason) { last.reasons.append(reason) }
                last.reasons.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                last.isConfirmed = last.isConfirmed || window.isConfirmed
                last.part = .combined
                merged[merged.count - 1] = last
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    // MARK: Timeline

    static func timeline(for instances: [DoseInstance], now: Date? = nil) -> [MedsTimelineEntry] {
        let windows = noFoodWindows(for: instances, now: now)
        var entries: [MedsTimelineEntry] = instances.map { .dose($0) }
        for (index, window) in windows.enumerated() {
            entries.append(.noFood(window))
            let nextStart = index + 1 < windows.count ? windows[index + 1].start : nil
            // A "before" part followed straight by its "after" part leaves no gap to eat in.
            if nextStart.map({ $0 > window.end }) ?? true {
                entries.append(.foodOK(start: window.end, until: nextStart))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.sortRank < rhs.sortRank
        }
    }

    /// Timeline grouped into Morning / Afternoon / Evening by each entry's position on the day.
    static func sections(for instances: [DoseInstance], now: Date? = nil) -> [(slot: DaySlot, entries: [MedsTimelineEntry])] {
        let entries = timeline(for: instances, now: now)
        return DaySlot.allCases.compactMap { slot in
            let inSlot = entries.filter { DaySlot.slot(forHour: calendar.component(.hour, from: $0.time)) == slot }
            return inSlot.isEmpty ? nil : (slot, inSlot)
        }
    }

    // MARK: Right now

    /// Yesterday's taken doses, so a no-food window that started late at night still shows after midnight.
    static func carryOver(into day: Date, medications: [Medication], logs: [DoseLog]) -> [DoseInstance] {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: day)) else { return [] }
        return instances(on: yesterday, medications: medications, logs: logs).filter(\.isTaken)
    }

    /// `carryOver` (see above) only contributes food windows, never due doses or counts.
    static func rightNow(instances: [DoseInstance], now: Date, carryOver: [DoseInstance] = []) -> RightNowState {
        let windows = noFoodWindows(for: carryOver + instances, now: now)
        let pending = instances.filter(\.isPending)
        let active = windows.first(where: { $0.contains(now) })
        // A due dose that needs an empty stomach beforehand: never say "Food OK" while it waits.
        let waiting = pending.first {
            $0.scheduledAt <= now && $0.medication.foodRule == .emptyStomach && $0.medication.noFoodBeforeMinutes > 0
        }
        let food: RightNowState.Food
        if let active, active.isConfirmed {
            food = .noFood(active)
        } else if let waiting {
            let before = Double(waiting.medication.noFoodBeforeMinutes) * 60
            food = .holdForDose(waiting, emptySince: now.addingTimeInterval(-before), eatingDelaysTo: now.addingTimeInterval(before))
        } else if let active {
            food = .noFood(active)
        } else {
            food = .foodOK(nextWindow: windows.first { $0.start > now })
        }
        return RightNowState(
            food: food,
            due: pending.filter { $0.scheduledAt <= now },
            next: pending.first { $0.scheduledAt > now },
            totalToday: instances.count,
            resolvedToday: instances.count - pending.count
        )
    }

    // MARK: Celebration & streak

    /// True when every dose in the slot is logged and at least one was taken.
    static func isSlotComplete(_ slot: DaySlot, instances: [DoseInstance]) -> Bool {
        let inSlot = instances.filter { $0.slot == slot }
        return !inSlot.isEmpty && inSlot.allSatisfy { !$0.isPending } && inSlot.contains(where: \.isTaken)
    }

    /// Consecutive days where every dose was logged (taken or skipped) and at least one was taken.
    /// Today counts only once complete, so an unfinished today never breaks the streak.
    static func gentleStreak(medications: [Medication], logs: [DoseLog], today: Date) -> Int {
        guard let earliest = medications.map(\.startDate).min() else { return 0 }
        let firstDay = calendar.startOfDay(for: earliest)
        var day = calendar.startOfDay(for: today)
        var streak = 0
        var isToday = true
        for _ in 0..<366 {
            guard day >= firstDay else { break }
            let instances = instances(on: day, medications: medications, logs: logs)
            let complete = !instances.isEmpty && instances.allSatisfy { !$0.isPending } && instances.contains(where: \.isTaken)
            if complete {
                streak += 1
            } else if !isToday && !instances.isEmpty {
                break
            }
            isToday = false
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}
