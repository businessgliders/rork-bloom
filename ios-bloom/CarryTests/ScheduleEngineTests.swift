//
//  ScheduleEngineTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// The scheduling engine, using the example sentence:
/// "Thyroid as soon as I wake up, no food for 30 min after. Iron 4 hours after thyroid,
/// no food 1 hour before or after. Prenatal with lunch. Keep iron and calcium 2 hours apart."
/// The rules are built by hand here, exactly as the parser is asked to return them.
struct ScheduleEngineTests {
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

    func routine(breakfast: Int = 7 * 60 + 30) -> EngineRoutine {
        EngineRoutine(wake: 7 * 60, bed: 22 * 60, meals: [
            EngineMeal(name: "Breakfast", start: breakfast, duration: 30),
            EngineMeal(name: "Lunch", start: 12 * 60 + 30, duration: 30),
            EngineMeal(name: "Dinner", start: 18 * 60 + 30, duration: 30),
        ])
    }

    @Test func exampleSentencePlacesEveryMedication() {
        let result = ScheduleEngine.generate(routine: routine(), meds: meds, rules: rules)
        #expect(result.times[thyroid] == 7 * 60)        // on waking
        #expect(result.times[iron] == 11 * 60)          // 4 h after thyroid, clear of breakfast and lunch
        #expect(result.times[prenatal] == 12 * 60 + 30) // with lunch
        #expect(result.times[calcium] == 7 * 60)        // 4 h from iron (rule: at least 2 h)
        #expect(result.violations.isEmpty)
    }

    @Test func sameInputGivesSameOutput() {
        let a = ScheduleEngine.generate(routine: routine(), meds: meds, rules: rules)
        let b = ScheduleEngine.generate(routine: routine(), meds: meds.reversed(), rules: rules.reversed())
        #expect(a.times == b.times)
    }

    @Test func impossibleRuleNamesTheRuleAndAFix() {
        // Breakfast 15 minutes after waking can't leave 30 minutes without food after thyroid.
        let result = ScheduleEngine.generate(routine: routine(breakfast: 7 * 60 + 15), meds: meds, rules: rules)
        #expect(result.times[thyroid] == 7 * 60)
        let broken = result.violations.first { $0.rule.subjectID == thyroid }
        #expect(broken != nil)
        #expect(broken?.message.contains("15 min before Breakfast") == true)
        #expect(broken?.message.contains("30 min") == true)
        #expect(broken?.fix?.contains("move Breakfast to") == true)
    }

    @Test func movingIronEarlyWarnsWithActualAndRequiredGap() {
        var times = ScheduleEngine.generate(routine: routine(), meds: meds, rules: rules).times
        times[iron] = 10 * 60
        let warnings = ScheduleEngine.violations(times: times, routine: routine(), rules: rules, names: names)
        #expect(warnings.map(\.message).contains("Iron is now 3 h after Thyroid; your rule is 4 h"))
    }

    @Test func shiftingTheStartKeepsTheGaps() {
        let times = [7 * 60, 7 * 60 + 30, 11 * 60, 12 * 60 + 30]
        let shifted = ScheduleEngine.shift(times, from: 0, by: 60)
        #expect(shifted == [8 * 60, 8 * 60 + 30, 12 * 60, 13 * 60 + 30])
        let partial = ScheduleEngine.shift(times, from: 2, by: -30)
        #expect(partial == [7 * 60, 7 * 60 + 30, 10 * 60 + 30, 12 * 60])
    }

    @Test func shiftingEverythingKeepsRulesSatisfied() {
        let base = ScheduleEngine.generate(routine: routine(), meds: meds, rules: rules).times
        let moved = base.mapValues { $0 + 60 }
        let later = EngineRoutine(wake: 8 * 60, bed: 23 * 60, meals: routine().meals.map {
            EngineMeal(name: $0.name, start: $0.start + 60, duration: $0.duration)
        })
        #expect(ScheduleEngine.violations(times: moved, routine: later, rules: rules, names: names).isEmpty)
    }

    @Test func reorderingPutsTheItemBetweenItsNeighbours() {
        // Thyroid 7:00, Breakfast 7:30, Iron 11:00, Prenatal 12:30 → drag Iron between Thyroid and Breakfast.
        let times = [7 * 60, 7 * 60 + 30, 11 * 60, 12 * 60 + 30]
        #expect(ScheduleEngine.timeAfterMove(times, from: 2, to: 1) == 7 * 60 + 15)
        #expect(ScheduleEngine.timeAfterMove(times, from: 0, to: 4) == 13 * 60)
    }

    @Test func reorderIntoBreakfastTriggersWarnings() {
        var times = ScheduleEngine.generate(routine: routine(), meds: meds, rules: rules).times
        times[iron] = 7 * 60 + 15
        let warnings = ScheduleEngine.violations(times: times, routine: routine(), rules: rules, names: names)
        #expect(warnings.contains { $0.message.hasPrefix("Iron is now 15 min after Thyroid") })
        #expect(warnings.contains { $0.message.contains("before Breakfast") })
    }

    @Test func lateThyroidRecalculatesTheRestOfToday() {
        // Thyroid taken at 8:00 instead of 7:00; it's 8:00 now.
        let pending = meds.filter { $0.id != thyroid }
        let result = ScheduleEngine.generate(routine: routine(), meds: pending, rules: rules,
                                             fixed: [thyroid: 8 * 60], earliest: 8 * 60)
        #expect(result.times[thyroid] == 8 * 60)
        // 12:00 would put lunch inside iron's hour without food, so it waits until an hour after lunch.
        #expect(result.times[iron] == 14 * 60)
        #expect(result.times[prenatal] == 12 * 60 + 30)
        #expect(result.times[calcium] == 8 * 60)
        #expect(result.violations.isEmpty)
    }

    @Test func pinnedTimesNeverMove() {
        var list = meds
        list[2].pinned = 21 * 60
        let result = ScheduleEngine.generate(routine: routine(), meds: list, rules: rules)
        #expect(result.times[prenatal] == 21 * 60)
        #expect(result.violations.contains { $0.rule.subjectID == prenatal })
    }

    @Test func rulesReadAsPlainText() {
        #expect(ScheduleEngine.describe(rules[2], names: names) == "Iron · at least 4 h after Thyroid")
        #expect(ScheduleEngine.describe(rules[0], names: names) == "Thyroid · as soon as you wake up")
        #expect(ScheduleEngine.describe(rules[1], names: names) == "Thyroid · no food for 30 min after")
        #expect(ScheduleEngine.describe(rules[5], names: names) == "Prenatal · with lunch")
        #expect(ScheduleEngine.describe(rules[6], names: names) == "Iron · at least 2 h apart from Calcium")
    }

    @Test func managedMedicationUsesItsDayPlan() {
        let cal = PregnancyMath.calendar
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        var med = Medication(name: "Iron", dose: "", startDate: cal.date(byAdding: .day, value: -3, to: today)!)
        med.managed = true
        med.times = []
        med.plan[PlanDay.key(today)] = DoseTime(hour: 11, minute: 0)
        let instances = MedsEngine.instances(on: today, medications: [med], logs: [])
        #expect(instances.count == 1)
        #expect(cal.component(.hour, from: instances[0].scheduledAt) == 11)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        #expect(MedsEngine.instances(on: tomorrow, medications: [med], logs: []).isEmpty)

        // A dose logged at the old time still counts after the plan moves.
        let log = DoseLog(medicationID: med.id, scheduledAt: cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!,
                          status: .taken, takenAt: cal.date(bySettingHour: 10, minute: 5, second: 0, of: today)!)
        let withLog = MedsEngine.instances(on: today, medications: [med], logs: [log])
        #expect(withLog.count == 1)
        #expect(withLog[0].isTaken)
    }

    @Test func weekdayLabels() {
        #expect(ScheduleTemplate.daysLabel(Set(0...6)) == "Every day")
        #expect(ScheduleTemplate.daysLabel([5, 6, 0]).contains("–") || ScheduleTemplate.daysLabel([5, 6, 0]).contains(","))
    }
}
