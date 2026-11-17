//
//  MealReplanTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// Board 20: re-planning the rest of today from the meals she actually ate. Meal times are when she finished.
struct MealReplanTests {
    let prenatalAM = UUID()
    let prenatalPM = UUID()
    let thyroid = UUID()

    var names: [UUID: String] { [prenatalAM: "Prenatal AM", prenatalPM: "Prenatal PM", thyroid: "Thyroid"] }

    /// Breakfast 7:30, lunch 12:00, dinner 6:30 PM, 30 minutes each.
    var routine: EngineRoutine {
        EngineRoutine(wake: 7 * 60, bed: 22 * 60, meals: [
            EngineMeal(name: "Breakfast", start: 7 * 60 + 30, duration: 30),
            EngineMeal(name: "Lunch", start: 12 * 60, duration: 30),
            EngineMeal(name: "Dinner", start: 18 * 60 + 30, duration: 30),
        ])
    }

    @Test func lateLunchInsideTheNoFoodWindowOffersTheEarliestTimeThatFits() throws {
        let rules = [ScheduleRule(subjectID: prenatalAM, relation: .after, target: .food, minMinutes: 120)]
        let input = MealReplanInput(
            routine: routine, eaten: ["Lunch": 13 * 60 + 30], times: [prenatalAM: 15 * 60], fixed: [],
            meds: [EngineMed(id: prenatalAM, name: "Prenatal AM")], rules: rules, range: 7 * 60...22 * 60, names: names
        )
        let result = MealReplan.compute(input)
        let clash = try #require(result.clashes.first)
        #expect(result.clashes.count == 1)
        #expect(clash.medicationID == prenatalAM)
        #expect(clash.from == 15 * 60)
        #expect(clash.to == 15 * 60 + 30)
        #expect(clash.title == "Late lunch affects Prenatal AM")
        #expect(result.times[prenatalAM] == 15 * 60) // nothing moves until she accepts
    }

    @Test func lateDinnerMovesTheDoseThatFollowsItWithoutACard() throws {
        // "Within 1 h after dinner": planned 7:30 PM after a dinner ending 7:00; she finished at 8:15.
        let rules = [ScheduleRule(subjectID: prenatalPM, relation: .after, target: .meal, targetMeal: "Dinner",
                                  minMinutes: 0, maxMinutes: 60)]
        let input = MealReplanInput(
            routine: routine, eaten: ["Dinner": 20 * 60 + 15], times: [prenatalPM: 19 * 60 + 30], fixed: [],
            meds: [EngineMed(id: prenatalPM, name: "Prenatal PM")], rules: rules, range: 7 * 60...22 * 60, names: names
        )
        let result = MealReplan.compute(input)
        let moved = try #require(result.times[prenatalPM])
        #expect((20 * 60 + 15)...(21 * 60 + 15) ~= moved)
        #expect(result.clashes.isEmpty)
        let adjust = try #require(result.follows[prenatalPM])
        #expect(adjust.from == 19 * 60 + 30)
        #expect(adjust.caption == "Follows dinner")
    }

    @Test func aTakenDoseIsNeverMovedOrSuggested() {
        // Thyroid taken at 7:15 needs 30 min without food; breakfast ran 7:30–8:00, but she's already taken it.
        let rules = [ScheduleRule(subjectID: thyroid, relation: .before, target: .food, minMinutes: 30)]
        let input = MealReplanInput(
            routine: routine, eaten: ["Breakfast": 7 * 60 + 40], times: [thyroid: 7 * 60 + 15], fixed: [thyroid],
            meds: [EngineMed(id: thyroid, name: "Thyroid")], rules: rules, range: 7 * 60...22 * 60, names: names
        )
        let result = MealReplan.compute(input)
        #expect(result.clashes.isEmpty)
        #expect(result.follows.isEmpty)
        #expect(result.times[thyroid] == 7 * 60 + 15)
    }

    @Test func aMealSoLateNoTimeIsLeftSaysSo() throws {
        // An hour without food either side; a dinner finishing at 9:50 PM leaves nothing before bed.
        let rules = [ScheduleRule(subjectID: prenatalPM, relation: .apart, target: .food, minMinutes: 60)]
        let input = MealReplanInput(
            routine: routine, eaten: ["Dinner": 21 * 60 + 50], times: [prenatalPM: 21 * 60], fixed: [],
            meds: [EngineMed(id: prenatalPM, name: "Prenatal PM")], rules: rules, range: 21 * 60...22 * 60, names: names
        )
        let result = MealReplan.compute(input)
        let clash = try #require(result.clashes.first)
        #expect(clash.to == nil)
        #expect(clash.fitLine == "No time left today keeps every rule.")
    }
}
