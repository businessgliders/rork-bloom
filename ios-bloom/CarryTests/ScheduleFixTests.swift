//
//  ScheduleFixTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// Fixing a day after she moves something: closest valid time, settling, one-tap fixes and the
/// explanation when a rule can't fit. Same example regimen as ScheduleEngineTests.
struct ScheduleFixTests {
    let thyroid = UUID()
    let iron = UUID()
    let prenatal = UUID()
    let calcium = UUID()

    var names: [UUID: String] { [thyroid: "Thyroid", iron: "Iron", prenatal: "Prenatal", calcium: "Calcium"] }

    var meds: [EngineMed] {
        [EngineMed(id: thyroid, name: "Thyroid"), EngineMed(id: iron, name: "Iron"),
         EngineMed(id: prenatal, name: "Prenatal"), EngineMed(id: calcium, name: "Calcium")]
    }

    var rules: [ScheduleRule] {
        [
            ScheduleRule(subjectID: thyroid, relation: .at, target: .wake, minMinutes: 0),
            ScheduleRule(subjectID: thyroid, relation: .before, target: .food, minMinutes: 30),
            ScheduleRule(subjectID: iron, relation: .after, target: .medication, targetMedicationID: thyroid, minMinutes: 240),
            ScheduleRule(subjectID: iron, relation: .after, target: .food, minMinutes: 60),
            ScheduleRule(subjectID: iron, relation: .before, target: .food, minMinutes: 60),
            ScheduleRule(subjectID: prenatal, relation: .with, target: .meal, targetMeal: "lunch"),
            ScheduleRule(subjectID: iron, relation: .apart, target: .medication, targetMedicationID: calcium, minMinutes: 120),
        ]
    }

    func routine(bed: Int = 22 * 60) -> EngineRoutine {
        EngineRoutine(wake: 7 * 60, bed: bed, meals: [
            EngineMeal(name: "Breakfast", start: 7 * 60 + 30, duration: 30),
            EngineMeal(name: "Lunch", start: 12 * 60 + 30, duration: 30),
            EngineMeal(name: "Dinner", start: 18 * 60 + 30, duration: 30),
        ])
    }

    var planned: [UUID: Int] { [thyroid: 7 * 60, iron: 11 * 60, prenatal: 12 * 60 + 30, calcium: 7 * 60] }

    @Test func closestValidFindsTheEarliestTimeThatKeepsEveryRule() {
        var times = planned
        times[iron] = 9 * 60 // dragged to 9:00: only 2 h after Thyroid
        let best = ScheduleEngine.closestValid(for: iron, near: 9 * 60, times: times, routine: routine(),
                                               rules: rules, range: 7 * 60...22 * 60)
        #expect(best == 11 * 60)
    }

    @Test func settleMovesOnlyWhatBreaks() {
        var times = planned
        times[thyroid] = 8 * 60 // Thyroid taken an hour late; it's locked
        let settled = ScheduleEngine.settle(times: times, locked: [thyroid], meds: meds, routine: routine(),
                                            rules: rules, range: 7 * 60...22 * 60)
        #expect(settled[thyroid] == 8 * 60)
        #expect(settled[iron] == 14 * 60)          // 12:00 would be in lunch's no-food hour; next is 2:00 PM
        #expect(settled[prenatal] == 12 * 60 + 30) // untouched
        #expect(settled[calcium] == 7 * 60)        // untouched
    }

    @Test func everyFixSatisfiesTheBrokenRule() throws {
        var times = planned
        times[iron] = 9 * 60
        let violations = ScheduleEngine.violations(times: times, routine: routine(), rules: rules, names: names)
        let v = try #require(violations.first { $0.rule.subjectID == iron && $0.rule.target == .medication && $0.rule.targetMedicationID == thyroid })
        let fixes = ScheduleEngine.fixes(for: v, times: times, fixed: [], routine: routine(), rules: rules,
                                         names: names, range: 7 * 60...22 * 60, allowSkip: true)
        #expect(!fixes.isEmpty)
        #expect(fixes.contains { $0.kind == .move(iron, 11 * 60) })
        #expect(fixes.contains { $0.kind == .skip(iron) })
        for fix in fixes {
            var after = times
            switch fix.kind {
            case .move(let id, let t): after[id] = t
            case .skip(let id): after[id] = nil
            case .retime(let tweak): after = tweak.times
            }
            let ironRules = rules.filter { $0.involves(iron) }
            let still = ScheduleEngine.violations(times: after, routine: routine(), rules: ironRules, names: names)
            #expect(still.isEmpty, "\(fix.title) leaves \(still.map(\.message))")
        }
    }

    @Test func ruleThatCannotFitIsExplainedWithAWorkingSuggestion() throws {
        // Bedtime 10:00 AM: Iron can't be 4 h after Thyroid (7:00) before bed.
        let early = routine(bed: 10 * 60)
        let range = 7 * 60...10 * 60
        var times = planned
        times[iron] = 9 * 60 + 30
        let ironRules = rules.filter { $0.involves(iron) && $0.target == .medication && $0.targetMedicationID == thyroid }
        let v = try #require(ScheduleEngine.violations(times: times, routine: early, rules: ironRules, names: names).first)
        let reason = ScheduleEngine.blockedReason(for: v, times: times, fixed: [], routine: early, rules: ironRules,
                                                  names: names, range: range)
        #expect(reason.contains("Iron needs"))
        #expect(reason.contains("after bedtime"))
        #expect(ScheduleEngine.closestValid(for: iron, near: times[iron]!, times: times, routine: early,
                                            rules: ironRules, range: range) == nil)
        // Today there's still a one-tap fix that keeps every rule: skip Iron.
        let fixes = ScheduleEngine.fixes(for: v, times: times, fixed: [], routine: early, rules: ironRules,
                                         names: names, range: range, allowSkip: true)
        #expect(fixes.map(\.kind) == [.skip(iron)])
    }

    @Test func routineThatCannotFitOffersADayChangeThatWorks() throws {
        // Same early bedtime, on the Routines screen (no skipping): the fix is a later bedtime.
        let early = routine(bed: 10 * 60)
        var times = planned
        times[iron] = 9 * 60 + 30
        let ironRules = rules.filter { $0.involves(iron) && $0.target == .medication && $0.targetMedicationID == thyroid }
        let v = try #require(ScheduleEngine.violations(times: times, routine: early, rules: ironRules, names: names).first)
        let fixes = ScheduleEngine.routineFixes(for: v, times: times, meds: meds, routine: early, rules: ironRules, names: names)
        let first = try #require(fixes.first)
        guard case .retime(let tweak) = first.kind else { Issue.record("expected a routine change"); return }
        #expect(tweak.bed == 11 * 60)
        var after = early
        after.bed = 11 * 60
        #expect(ScheduleEngine.violations(times: tweak.times, routine: after, rules: ironRules, names: names).isEmpty)
    }

    @Test func loggedDosesAreNeverMovedBySettling() {
        var times = planned
        times[iron] = 9 * 60 // logged early
        let settled = ScheduleEngine.settle(times: times, locked: [iron], meds: meds, routine: routine(),
                                            rules: rules, range: 9 * 60...22 * 60)
        #expect(settled[iron] == 9 * 60)
        #expect(settled[calcium] == 7 * 60) // still 2 h from Iron; Thyroid stays at wake
    }
}
