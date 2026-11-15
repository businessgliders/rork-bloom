//
//  BloomTests.swift
//  BloomTests
//

import Foundation
import Testing
@testable import Bloom

/// Midnight rollover: yesterday stays logged, today starts fresh, the streak stays right,
/// and a late-night no-food window carries past midnight.
@MainActor
struct MidnightRolloverTests {
    let cal = PregnancyMath.calendar

    /// A fixed "today" so tests don't depend on the clock.
    var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14))! }

    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset))!
    }

    func med(times: [DoseTime] = [DoseTime(hour: 8, minute: 0), DoseTime(hour: 20, minute: 0)], startOffset: Int = -5,
             foodRule: FoodRule = .any, after: Int = 0) -> Medication {
        Medication(name: "Iron", dose: "1 tablet", times: times, foodRule: foodRule,
                   noFoodAfterMinutes: after, startDate: day(startOffset))
    }

    func taken(_ m: Medication, _ offset: Int, _ hour: Int, _ minute: Int = 0, lateBy: Double = 0) -> DoseLog {
        let scheduled = at(offset, hour, minute)
        return DoseLog(medicationID: m.id, scheduledAt: scheduled, status: .taken, takenAt: scheduled.addingTimeInterval(lateBy * 60))
    }

    @Test func yesterdayStaysLoggedAndTodayStartsFresh() {
        let m = med()
        let logs = [taken(m, -1, 8), taken(m, -1, 20)]

        let yesterday = MedsEngine.instances(on: day(-1), medications: [m], logs: logs)
        #expect(yesterday.count == 2)
        #expect(yesterday.allSatisfy { $0.isTaken })

        let todayInstances = MedsEngine.instances(on: at(0, 0, 1), medications: [m], logs: logs)
        #expect(todayInstances.count == 2)
        #expect(todayInstances.allSatisfy { $0.isPending })

        let rn = MedsEngine.rightNow(instances: todayInstances, now: at(0, 0, 1))
        #expect(rn.resolvedToday == 0)
        #expect(rn.totalToday == 2)
        #expect(rn.due.isEmpty)
        #expect(rn.next?.scheduledAt == at(0, 8))
    }

    @Test func lateLogJustBeforeMidnightBelongsToItsOwnDay() {
        let m = med(times: [DoseTime(hour: 23, minute: 45)])
        // Taken 10 minutes late, after midnight. It stays yesterday's dose.
        let logs = [taken(m, -1, 23, 45, lateBy: 10)]
        #expect(MedsEngine.instances(on: day(-1), medications: [m], logs: logs).first?.isTaken == true)
        #expect(MedsEngine.instances(on: day(0), medications: [m], logs: logs).first?.isPending == true)
    }

    @Test func streakCountsCompletedPastDaysAndIgnoresUnfinishedToday() {
        let m = med(startOffset: -3)
        let logs = (-3 ... -1).flatMap { [taken(m, $0, 8), taken(m, $0, 20)] }
        // Just after midnight: today is unfinished but doesn't break the streak.
        #expect(MedsEngine.gentleStreak(medications: [m], logs: logs, today: at(0, 0, 5)) == 3)
        // Today completed: it counts.
        let full = logs + [taken(m, 0, 8), taken(m, 0, 20)]
        #expect(MedsEngine.gentleStreak(medications: [m], logs: full, today: at(0, 21)) == 4)
    }

    @Test func streakBreaksOnAMissedPastDayButSkipsStillCount() {
        let m = med(startOffset: -3)
        var logs = [taken(m, -3, 8), taken(m, -3, 20), taken(m, -1, 8), taken(m, -1, 20)]
        // Day -2 left unlogged: streak is just yesterday.
        #expect(MedsEngine.gentleStreak(medications: [m], logs: logs, today: at(0, 0, 5)) == 1)
        // A logged skip keeps the day complete (gentle streak).
        logs += [taken(m, -2, 8), DoseLog(medicationID: m.id, scheduledAt: at(-2, 20), status: .skipped)]
        #expect(MedsEngine.gentleStreak(medications: [m], logs: logs, today: at(0, 0, 5)) == 3)
    }

    @Test func lateNightNoFoodWindowCarriesPastMidnight() {
        let m = med(times: [DoseTime(hour: 23, minute: 30)], foodRule: .emptyStomach, after: 60)
        let logs = [taken(m, -1, 23, 30, lateBy: 10)] // window 23:40 → 00:40
        let now = at(0, 0, 15)
        let todayInstances = MedsEngine.instances(on: now, medications: [m], logs: logs)
        let carry = MedsEngine.carryOver(into: now, medications: [m], logs: logs)

        let withoutCarry = MedsEngine.rightNow(instances: todayInstances, now: now)
        if case .noFood = withoutCarry.food { Issue.record("Without carry-over the window shouldn't be known") }

        let rn = MedsEngine.rightNow(instances: todayInstances, now: now, carryOver: carry)
        guard case .noFood(let window) = rn.food else {
            Issue.record("Expected the no-food window to still be running at 00:15")
            return
        }
        #expect(window.end == at(0, 0, 40))
        #expect(window.isConfirmed)
        // Carry-over never counts toward today's doses.
        #expect(rn.totalToday == 1)
        #expect(rn.resolvedToday == 0)
    }

    @Test func liveActivityContentFollowsTheDay() {
        let m = med(times: [DoseTime(hour: 8, minute: 0)], foodRule: .emptyStomach, after: 30)
        // 06:30: nothing within the hour → no activity.
        let early = MedsEngine.instances(on: at(0, 6, 30), medications: [m], logs: [])
        #expect(LiveActivityContent.make(instances: early, now: at(0, 6, 30)) == nil)

        // 07:30: upcoming dose, stale when it becomes due.
        let upcoming = LiveActivityContent.make(instances: early, now: at(0, 7, 30))
        #expect(upcoming?.state.dose?.isDue == false)
        #expect(upcoming?.staleDate == at(0, 8))
        #expect(upcoming?.state.staleReason == .doseDue)

        // Taken at 08:10 → confirmed window until 08:40, stale at its end.
        let logs = [taken(m, 0, 8, lateBy: 10)]
        let after = MedsEngine.instances(on: at(0, 8, 20), medications: [m], logs: logs)
        let window = LiveActivityContent.make(instances: after, now: at(0, 8, 20))
        #expect(window?.state.dose == nil)
        #expect(window?.state.windowEnd == at(0, 8, 40))
        #expect(window?.state.staleReason == .windowEnds)

        // 08:45: window over, all done → activity ends.
        #expect(LiveActivityContent.make(instances: after, now: at(0, 8, 45)) == nil)
    }
}
