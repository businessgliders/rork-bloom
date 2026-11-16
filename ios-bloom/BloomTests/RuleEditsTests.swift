//
//  RuleEditsTests.swift
//  BloomTests
//

import Foundation
import Testing
@testable import Bloom

/// The editable rule rows on the plan screen: which control each rule gets, how steppers move, and the row wording.
struct RuleEditsTests {
    let thyroid = UUID()
    let iron = UUID()
    let pm = UUID()

    var names: [UUID: String] { [thyroid: "Thyroid", iron: "Iron", pm: "Progesterone PM"] }

    @Test func noFoodRuleIsAMinuteStepper() {
        let rule = ScheduleRule(subjectID: thyroid, relation: .before, target: .food, minMinutes: 30)
        #expect(RuleValues.control(for: rule) == .minutes(step: 15, lowest: 15))
        #expect(RuleValues.title(rule, names: names).hasPrefix("No food after · 30"))
    }

    @Test func medicationGapStepsByTheHour() {
        let rule = ScheduleRule(subjectID: iron, relation: .after, target: .medication, targetMedicationID: thyroid, minMinutes: 240)
        #expect(RuleValues.control(for: rule) == .minutes(step: 60, lowest: 15))
        #expect(RuleValues.title(rule, names: names).hasPrefix("At least 4"))
        #expect(RuleValues.title(rule, names: names).hasSuffix("after Thyroid"))
        #expect(RuleValues.stepped(240, up: true, lowest: 15) == 300)
        #expect(RuleValues.stepped(60, up: false, lowest: 15) == 45)
        #expect(RuleValues.stepped(15, up: false, lowest: 15) == 15)
    }

    @Test func mealRuleGetsAMealPicker() {
        let rule = ScheduleRule(subjectID: iron, relation: .with, target: .meal, targetMeal: "Lunch", minMinutes: 0)
        #expect(RuleValues.control(for: rule) == .meal)
        #expect(RuleValues.title(rule, names: names) == "With lunch")
    }

    @Test func apartWindowIsARange() {
        let rule = ScheduleRule(subjectID: thyroid, relation: .apart, target: .medication, targetMedicationID: pm,
                                minMinutes: 600, maxMinutes: 720)
        #expect(RuleValues.control(for: rule) == .range(step: 60))
    }

    /// The plan written back as text (start over) keeps her medication order and reads "before bed" as "at bedtime".
    @MainActor @Test func startOverTextKeepsHerOrder() {
        let text = "Thyroid\nThyroid at least 4 h before Prenatal vitamin\n\nProgesterone PM\nProgesterone PM at bedtime\n\nPrenatal vitamin"
        let parses: [Int: LineParse] = [
            0: LineParse(meds: [.init(name: "Thyroid")]),
            1: LineParse(meds: [.init(name: "Thyroid"), .init(name: "Prenatal vitamin")],
                         rules: [.init(subject: "Thyroid", relation: "before", targetType: "medication", target: "Prenatal vitamin", min: 240)]),
            3: LineParse(meds: [.init(name: "Progesterone PM")]),
            4: LineParse(meds: [.init(name: "Progesterone PM")],
                         rules: [.init(subject: "Progesterone PM", relation: "before", targetType: "bed", min: 0)]),
            6: LineParse(meds: [.init(name: "Prenatal vitamin")]),
        ]
        let result = RegimenAssembler.assemble(text: text, lineParses: parses, existing: [])
        #expect(result.drafts.map(\.name) == ["Thyroid", "Progesterone PM", "Prenatal vitamin"])
        let bed = result.rules.first { $0.target == .bed }
        #expect(bed?.relation == .at)
    }

    @Test func signaturesIgnoreRuleIDsAndOrder() {
        let a = ScheduleRule(subjectID: thyroid, relation: .before, target: .food, minMinutes: 30)
        let b = ScheduleRule(subjectID: iron, relation: .with, target: .meal, targetMeal: "Lunch", minMinutes: 0)
        let a2 = ScheduleRule(subjectID: thyroid, relation: .before, target: .food, minMinutes: 30)
        let b2 = ScheduleRule(subjectID: iron, relation: .with, target: .meal, targetMeal: "lunch", minMinutes: 0)
        #expect(RuleSignature.same([a, b], [b2, a2]))
        #expect(RuleSignature.contains([a, b], a2))
        var longer = a2
        longer.minMinutes = 45
        #expect(!RuleSignature.same([a, b], [longer, b2]))
    }
}
