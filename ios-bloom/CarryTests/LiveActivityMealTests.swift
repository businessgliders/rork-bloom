//
//  LiveActivityMealTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// Meals on the Live Activity: shown when due or within the hour, hidden during a no-food
/// window, listed as "Then" under a dose, and they keep the activity alive.
@MainActor
struct LiveActivityMealTests {
    let cal = PregnancyMath.calendar
    var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 18))! }

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
    }

    func slot(_ kind: MealKind, _ name: String, _ hour: Int, _ minute: Int = 0, minutes: Int = 30) -> LiveActivityContent.MealSlot {
        .init(kind: kind, name: name, start: at(hour, minute), end: at(hour, minute).addingTimeInterval(Double(minutes) * 60))
    }

    var meals: [LiveActivityContent.MealSlot] {
        [slot(.breakfast, "Breakfast", 9, 30), slot(.lunch, "Lunch", 12), slot(.dinner, "Dinner", 19)]
    }

    func thyroid() -> Medication {
        Medication(name: "Thyroid", dose: "1 tablet", times: [DoseTime(hour: 8, minute: 0)], foodRule: .emptyStomach,
                   noFoodAfterMinutes: 30, startDate: cal.date(byAdding: .day, value: -5, to: today)!)
    }

    func taken(_ m: Medication, at time: Date) -> DoseLog {
        DoseLog(medicationID: m.id, scheduledAt: at(8), status: .taken, takenAt: time)
    }

    @Test func mealAloneKeepsTheActivityAliveAndCountsDown() {
        // 11:52, nothing else on: lunch at 12:00 is the card, stale when it starts.
        let result = LiveActivityContent.make(instances: [], now: at(11, 52), meals: meals)
        #expect(result?.state.meal?.key == "lunch")
        #expect(result?.state.meal?.isDue == false)
        #expect(result?.staleDate == at(12))
        #expect(result?.state.staleReason == .mealDue)
        // Due once it starts, and it stays until an hour past its end.
        #expect(LiveActivityContent.make(instances: [], now: at(12, 5), meals: meals)?.state.meal?.isDue == true)
        #expect(LiveActivityContent.make(instances: [], now: at(13, 25), meals: meals)?.state.meal?.key == "lunch")
        #expect(LiveActivityContent.make(instances: [], now: at(13, 35), meals: meals) == nil)
    }

    @Test func nothingWithinTheHourEndsTheActivity() {
        #expect(LiveActivityContent.make(instances: [], now: at(10, 45), meals: [slot(.lunch, "Lunch", 12)]) == nil)
    }

    @Test func mealIsHiddenWhileAWindowRunsAndShowsAfter() {
        let m = thyroid()
        let logs = [taken(m, at: at(8, 1))] // window 08:01 → 08:31
        let instances = MedsEngine.instances(on: at(8, 20), medications: [m], logs: logs)

        let during = LiveActivityContent.make(instances: instances, now: at(8, 20), meals: [slot(.breakfast, "Breakfast", 8, 15)])
        #expect(during?.state.windowEnd == at(8, 31))
        #expect(during?.state.meal == nil)

        // After the window: breakfast shows (with Eaten on the card).
        let after = LiveActivityContent.make(instances: instances, now: at(8, 35), meals: [slot(.breakfast, "Breakfast", 8, 15)])
        #expect(after?.state.hasWindow == false)
        #expect(after?.state.meal?.key == "breakfast")
        #expect(after?.state.meal?.isDue == true)
    }

    @Test func doseAndMealBothComeThrough() {
        // 08:50: a 09:00 dose and 09:30 breakfast. The dose leads; the meal rides along as "Then".
        let iron = Medication(name: "Iron", dose: "1 tablet", times: [DoseTime(hour: 9, minute: 0)],
                              startDate: cal.date(byAdding: .day, value: -5, to: today)!)
        let instances = MedsEngine.instances(on: at(8, 50), medications: [iron], logs: [])
        let result = LiveActivityContent.make(instances: instances, now: at(8, 50), meals: meals)
        #expect(result?.state.dose?.name == iron.shortName)
        #expect(result?.state.meal?.key == "breakfast")
        // Stale at the earlier of the two.
        #expect(result?.staleDate == at(9))
        #expect(result?.state.staleReason == .doseDue)
    }

    @Test func oldPayloadWithoutMealStillDecodes() throws {
        let json = #"{"otherDueCount":0,"resolved":1,"total":3,"staleReason":"none"}"#
        let state = try JSONDecoder().decode(BloomActivityAttributes.ContentState.self, from: Data(json.utf8))
        #expect(state.meal == nil)
        #expect(state.total == 3)
    }

    @Test func pushedMealDecodesFromUnixSeconds() throws {
        let start = at(12).timeIntervalSince1970
        let json = """
        {"otherDueCount":0,"resolved":2,"total":5,"staleReason":"mealDue",
         "meal":{"key":"lunch","name":"Lunch","startAt":\(start),"endAt":\(start + 1800),"isDue":false}}
        """
        let state = try JSONDecoder().decode(BloomActivityAttributes.ContentState.self, from: Data(json.utf8))
        #expect(state.meal?.startAt == at(12))
        #expect(state.meal?.name == "Lunch")
        #expect(state.staleReason == .mealDue)
    }
}
