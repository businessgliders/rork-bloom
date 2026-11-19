import Foundation
import Testing
@testable import Carry

/// Doses tied by a gap rule are placed together, counting the night between days.
struct LinkedGapTests {
    let am = UUID()
    let pm = UUID()
    let wake = 8 * 60
    let bed = 22 * 60 + 30

    var meds: [EngineMed] { [EngineMed(id: am, name: "Progesterone AM"), EngineMed(id: pm, name: "Progesterone PM")] }

    func rules(min: Int, max: Int? = nil, bothWays: Bool = true) -> [ScheduleRule] {
        var list = [
            ScheduleRule(subjectID: pm, relation: .at, target: .bed, minMinutes: 0),
            ScheduleRule(subjectID: am, relation: .apart, target: .medication, targetMedicationID: pm, minMinutes: min, maxMinutes: max),
        ]
        if bothWays {
            list.append(ScheduleRule(subjectID: pm, relation: .apart, target: .medication, targetMedicationID: am, minMinutes: min, maxMinutes: max))
        }
        return list
    }

    var everyDay: ScheduleTemplate {
        ScheduleTemplate(name: "Every day", days: Set(0...6), wake: DoseTime(minutes: wake), bed: DoseTime(minutes: bed), meals: [
            ScheduleMeal(name: "Breakfast", time: DoseTime(minutes: wake + 30)),
            ScheduleMeal(name: "Lunch", time: DoseTime(minutes: 12 * 60 + 30)),
            ScheduleMeal(name: "Dinner", time: DoseTime(minutes: 18 * 60 + 30)),
        ])
    }

    func place(_ rules: [ScheduleRule]) -> (am: Int?, pm: Int?, violations: [RuleViolation]) {
        let (placed, found) = ScheduleCycle.generateAll([everyDay], meds: { _ in meds }, rules: { _ in rules })
        return (placed[0].dose(for: am)?.time.minutesFromMidnight, placed[0].dose(for: pm)?.time.minutesFromMidnight,
                found[placed[0].id] ?? [])
    }

    @Test func twelveHoursBothWaysFitsAtTenThirty() {
        let r = place(rules(min: 720))
        #expect(r.am == 10 * 60 + 30)
        #expect(r.pm == 22 * 60 + 30)
        #expect(r.violations.isEmpty)
    }

    @Test func settleMovesThePairFromTheOldTimes() {
        let routine = EngineRoutine(wake: wake, bed: bed, meals: [], mirrorNext: true, mirrorPrevious: true)
        let times = ScheduleEngine.settle(times: [am: 8 * 60 + 30, pm: 22 * 60 + 30], locked: [], meds: meds,
                                          routine: routine, rules: rules(min: 720), range: wake...bed)
        #expect(times[am] == 10 * 60 + 30)
        #expect(times[pm] == 22 * 60 + 30)
    }

    @Test func thirteenHoursCannotFitOneWarning() {
        // 13 h each way needs a 26 h day: one warning for the rule written both ways.
        let r = place(rules(min: 780))
        #expect(r.violations.count == 1)
    }

    @Test func elevenToThirteenFits() {
        let r = place(rules(min: 660, max: 780))
        #expect(r.violations.isEmpty)
    }

    @Test func mirroredRulesAreOneRule() {
        let list = rules(min: 720)
        #expect(RuleSignature.mirrors(list[1], list[2]))
        #expect(!RuleSignature.mirrors(list[0], list[1]))
    }
}

/// Days from her lines ("Protein Tue and Thu").
struct LineDaysTests {
    func date(_ day: Int) -> Date {
        // 2026-11-20 is a Friday.
        PregnancyMath.calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }

    @Test func decodeReadsDays() throws {
        let parse = try LineParseService.decode(#"{"meds":[{"name":"Protein","days":[2,4]}],"rules":[]}"#)
        let schedule = parse.meds.first?.schedule
        #expect(schedule == .weekdays([3, 5]))
        #expect(schedule?.includes(date(24)) == true)   // Tue
        #expect(schedule?.includes(date(26)) == true)   // Thu
        #expect(schedule?.includes(date(20)) == false)  // Fri
        #expect(schedule?.includes(date(21)) == false)  // Sat
        #expect(schedule?.includes(date(25)) == false)  // Wed
    }

    @Test func everyMondayMovesToMondays() throws {
        let parse = try LineParseService.decode(#"{"meds":[{"name":"Protein","days":[1]}],"rules":[]}"#)
        let schedule = parse.meds.first?.schedule
        #expect(schedule == .weekdays([2]))
        #expect(schedule?.includes(date(23)) == true)
        #expect(schedule?.includes(date(24)) == false)
    }

    @Test func noDaysMeansNoChange() throws {
        let parse = try LineParseService.decode(#"{"meds":[{"name":"Iron"}],"rules":[]}"#)
        #expect(parse.meds.first?.schedule == nil)
    }

    @MainActor @Test func summaryShowsTheDays() {
        let text = "Protein Tue and Thu\nIron"
        let parses: [Int: LineParse] = [
            0: LineParse(meds: [.init(name: "Protein", days: [2, 4])]),
            1: LineParse(meds: [.init(name: "Iron")]),
        ]
        let result = RegimenAssembler.assemble(text: text, lineParses: parses, existing: [])
        #expect(result.drafts.first { $0.name == "Protein" }?.schedule == .weekdays([3, 5]))
        #expect(result.drafts.first { $0.name == "Iron" }?.schedule == nil)
        #expect(result.lines[0].items.contains { $0.contains("Protein") && $0.contains("Tue, Thu") })
        #expect(MedSchedule.weekdays([3, 5]).daysNote == "Tue, Thu")
        #expect(MedSchedule.daily.daysNote == nil)
    }
}
