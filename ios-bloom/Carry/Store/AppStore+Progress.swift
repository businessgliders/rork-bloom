import Foundation

/// One day in the streak chart: share of doses taken, and whether one was missed.
struct StreakBar: Equatable, Identifiable {
    enum Kind: Equatable { case past, today, future, nothingPlanned }
    var day: Date
    var share: Double
    var missed: Bool
    var kind: Kind
    var id: Date { day }
}

/// One fact on How it's going. Factual, never scolding.
struct ProgressObservation: Identifiable, Equatable {
    enum Kind: Equatable { case onTime, late(UUID), unlogged }
    var kind: Kind
    var title: String
    var detail: String
    var id: String { title }
}

/// Counts for Meds today, the week strip and How it's going. Computed on the phone from logs and the plan.
extension AppStore {
    /// The signed-in person's meds; if they take none, the partner's day.
    var medsPerson: MedOwner {
        let me = viewerRole
        if medications.contains(where: { $0.owner == me }) { return me }
        let other: MedOwner = me == .mom ? .partner : .mom
        if medications.contains(where: { $0.owner == other }) { return other }
        return me
    }

    /// Both people have medications that haven't ended: Meds shows the Mine / partner switch.
    var bothTakeMeds: Bool {
        MedOwner.allCases.allSatisfy { !currentMedications(for: $0).isEmpty }
    }

    /// The person Meds today and Meds & routines show: the switch when both take meds, else `medsPerson`.
    var shownMedsPerson: MedOwner {
        guard bothTakeMeds else { return medsPerson }
        return medsShowsPartner ? viewerRole.other : viewerRole
    }

    /// Points the person switch at `owner` (a deep link or a swipe). No-op without the switch.
    func showMeds(of owner: MedOwner) {
        guard bothTakeMeds else { return }
        let partner = owner != viewerRole
        if medsShowsPartner != partner { medsShowsPartner = partner }
    }

    func meds(of owner: MedOwner) -> [Medication] {
        medications.filter { $0.owner == owner }
    }

    func instances(_ owner: MedOwner, on day: Date) -> [DoseInstance] {
        MedsEngine.instances(on: day, medications: meds(of: owner), logs: doseLogs)
    }

    /// A day counts when every planned dose is logged as taken or skipped.
    private func isComplete(_ list: [DoseInstance]) -> Bool {
        !list.isEmpty && list.allSatisfy { !$0.isPending }
    }

    /// Current run of complete days (today counts once it is complete) and the best run.
    func streak(_ owner: MedOwner) -> (current: Int, best: Int) {
        let mine = meds(of: owner)
        guard let earliest = mine.map(\.startDate).min() else { return (0, 0) }
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: now)
        let first = max(cal.startOfDay(for: earliest), PregnancyMath.addDays(-365, to: today))
        var day = first
        var run = 0
        var best = 0
        var current = 0
        while day <= today {
            let list = MedsEngine.instances(on: day, medications: mine, logs: doseLogs)
            let isToday = day == today
            if list.isEmpty {
                // Nothing planned: neither adds nor breaks.
            } else if isComplete(list) {
                run += 1
            } else if !isToday {
                run = 0
            }
            best = max(best, run)
            current = run
            day = PregnancyMath.addDays(1, to: day)
        }
        return (current, best)
    }

    /// Logged and planned doses over the last 7 days (today included), and how many were taken on time.
    func weekCounts(_ owner: MedOwner) -> (logged: Int, planned: Int, onTime: Int) {
        var logged = 0, planned = 0, onTime = 0
        for list in lastDays(owner, count: 7) {
            planned += list.count
            logged += list.filter { !$0.isPending }.count
            onTime += list.filter { $0.isTaken && abs($0.minutesLate ?? 0) <= 30 }.count
        }
        return (logged, planned, onTime)
    }

    /// This week so far (the week strip's Sunday through now): doses due, taken, and missed.
    /// Due = planned time has passed, or already logged. Missed = skipped, or still not logged an hour after its time.
    func weekSummary(_ owner: MedOwner) -> (due: Int, taken: Int, missed: Int) {
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: now)
        let sunday = PregnancyMath.addDays(-(cal.component(.weekday, from: today) - 1), to: today)
        var due = 0, taken = 0, missed = 0
        var day = sunday
        while day <= today {
            for i in instances(owner, on: day) where i.scheduledAt <= now || !i.isPending {
                due += 1
                if i.isTaken { taken += 1 }
                else if i.isSkipped || i.scheduledAt < now.addingTimeInterval(-3600) { missed += 1 }
            }
            day = PregnancyMath.addDays(1, to: day)
        }
        return (due, taken, missed)
    }

    /// The last `count` days, oldest first, each as its dose instances.
    func lastDays(_ owner: MedOwner, count: Int) -> [[DoseInstance]] {
        let today = PregnancyMath.calendar.startOfDay(for: now)
        return (0..<count).reversed().map { instances(owner, on: PregnancyMath.addDays(-$0, to: today)) }
    }

    /// The last 14 days, rolling, ending today (today is the rightmost bar; no future days).
    func streakBars(_ owner: MedOwner) -> [StreakBar] {
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: now)
        let start = PregnancyMath.addDays(-13, to: today)
        return (0..<14).map { offset in
            let day = PregnancyMath.addDays(offset, to: start)
            let list = instances(owner, on: day)
            guard !list.isEmpty else { return StreakBar(day: day, share: 0, missed: false, kind: .nothingPlanned) }
            let taken = list.filter(\.isTaken).count
            let late = now.addingTimeInterval(-3600)
            let missed = list.contains { $0.isSkipped || ($0.isPending && (day < today || $0.scheduledAt < late)) }
            return StreakBar(day: day, share: Double(taken) / Double(list.count), missed: missed,
                             kind: day == today ? .today : .past)
        }
    }

    /// Green dot = all logged, sand = some logged, nil = nothing logged or nothing planned.
    func dayMark(_ owner: MedOwner, on day: Date) -> Bool? {
        let list = instances(owner, on: day)
        guard !list.isEmpty else { return nil }
        let done = list.filter { !$0.isPending }.count
        if done == list.count { return true }
        return done > 0 ? false : nil
    }

    /// Up to three facts from the last week.
    func observations(_ owner: MedOwner) -> [ProgressObservation] {
        var out: [ProgressObservation] = []
        let days = lastDays(owner, count: 7)
        let past = days.dropLast()

        // On-time run, counted back from yesterday (today joins once its doses are all on time).
        var run = 0
        for list in days.reversed() {
            let taken = list.filter(\.isTaken)
            let isToday = list.first.map { PregnancyMath.calendar.isDate($0.scheduledAt, inSameDayAs: now) } ?? false
            if list.isEmpty { continue }
            if taken.count == list.count, taken.allSatisfy({ abs($0.minutesLate ?? 0) <= 30 }) { run += 1 }
            else if isToday { continue } else { break }
        }
        if run >= 2 {
            out.append(.init(kind: .onTime, title: "\(run) days in a row on time",
                             detail: "Every dose was taken within 30 minutes of its planned time."))
        }

        // A medication often taken late.
        var lateBy: [UUID: [Int]] = [:]
        var names: [UUID: String] = [:]
        for list in past {
            for i in list where i.isTaken {
                if let late = i.minutesLate, late > 30 {
                    lateBy[i.medication.id, default: []].append(late)
                    names[i.medication.id] = i.medication.shortName
                }
            }
        }
        if let (id, lates) = lateBy.max(by: { $0.value.count < $1.value.count }), lates.count >= 3, let name = names[id] {
            let avg = lates.reduce(0, +) / lates.count
            let amount = avg >= 90 ? "about \(Int((Double(avg) / 60).rounded())) h" : "about \(Int((Double(avg) / 5).rounded()) * 5) min"
            out.append(.init(kind: .late(id), title: "\(name) is often later than planned",
                             detail: "Taken \(amount) late on \(lates.count) of the last 6 days."))
        }

        // Doses not logged this week (before now).
        let missing = days.flatMap { $0 }.filter { $0.isPending && $0.scheduledAt < now.addingTimeInterval(-3600) }.count
        if missing > 0 {
            out.append(.init(kind: .unlogged, title: missing == 1 ? "1 dose not logged this week" : "\(missing) doses not logged this week",
                             detail: "If you took them, you can still log them from that day."))
        }
        return Array(out.prefix(3))
    }
}
