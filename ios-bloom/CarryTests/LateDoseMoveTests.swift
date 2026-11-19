//
//  LateDoseMoveTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

/// "Progesterone AM and PM at least 10 h apart": a late PM moves tomorrow's AM by itself, an on-time PM doesn't,
/// and a gap rule with one number is a minimum only.
struct LateDoseMoveTests {
    let am = UUID()
    let pm = UUID()

    var gap: ScheduleRule {
        ScheduleRule(subjectID: am, relation: .apart, target: .medication, targetMedicationID: pm, minMinutes: 600)
    }

    var meds: [EngineMed] { [EngineMed(id: am, name: "Progesterone AM"), EngineMed(id: pm, name: "Progesterone PM")] }

    /// Tomorrow as planned: AM 8:30, PM 10:30 PM. `lastPM` is last night's PM, minutes after midnight (rounded to 5).
    func tomorrow(lastPM: Int, extra: [ScheduleRule] = []) -> LateDoseMove {
        let times = [am: 8 * 60 + 30, pm: 22 * 60 + 30]
        let previous = [am: [10 * 60 + 30 - 1440], pm: [lastPM - 1440]]
        let adjacent = EngineRoutine.adjacent(previous: [am: [10 * 60 + 30], pm: [lastPM]], next: [am: [8 * 60 + 30], pm: [22 * 60 + 30]])
        let routine = EngineRoutine(wake: 7 * 60, bed: 23 * 60, meals: [], adjacent: adjacent)
        let rules = [gap] + extra
        let usable = rules + ScheduleEngine.dayBounds(for: times.keys)
        return LateDoseMove.evaluate(times: times, fixed: [], pinned: [], previous: previous, meds: meds, routine: routine,
                                     gapRules: rules, usable: usable, range: (7 * 60)...(23 * 60))
    }

    @Test func latePMMovesTomorrowsAMTo945() {
        // Taken 11:46 PM, which counts as 11:45 PM.
        #expect(ScheduleEngine.roundNearest(23 * 60 + 46) == 23 * 60 + 45)
        let result = tomorrow(lastPM: 23 * 60 + 45)
        #expect(result == .moved([am: 9 * 60 + 45], causes: [pm]))
    }

    @Test func onTimePMMovesNothing() {
        #expect(tomorrow(lastPM: 22 * 60 + 30) == .none)
    }

    @Test func moveThatBreaksAnotherRuleDoesNotHappen() {
        // AM is also "on waking": moving it would break that, so it stays and the row warns instead.
        let onWaking = ScheduleRule(subjectID: am, relation: .at, target: .wake, minMinutes: 90)
        #expect(tomorrow(lastPM: 23 * 60 + 45, extra: [onWaking]) == .blocked)
    }

    @Test func amAt1028AndPMAt1146IsNoWarning() {
        let times = [am: 10 * 60 + 28, pm: 23 * 60 + 46]
        let routine = EngineRoutine(wake: 7 * 60, bed: 23 * 60 + 59, meals: [])
        let names = [am: "Progesterone AM", pm: "Progesterone PM"]
        #expect(ScheduleEngine.violations(times: times, routine: routine, rules: [gap], names: names).isEmpty)
        // The old reading (exactly 10 h) warned here.
        var exact = gap
        exact.maxMinutes = 600
        #expect(!ScheduleEngine.violations(times: times, routine: routine, rules: [exact], names: names).isEmpty)
    }

    @MainActor @Test func oneNumberIsAMinimum() {
        let rule = LineParse.Rule(subject: "Progesterone AM", relation: "apart", targetType: "medication",
                                  target: "Progesterone PM", min: 600, max: 600)
        let parse = LineParse(meds: [.init(name: "Progesterone AM"), .init(name: "Progesterone PM")], rules: [rule])
        let loose = LineParseService.validated(parse, line: "Progesterone AM and PM 10 hours apart")
        #expect(loose.rules.first?.min == 600)
        #expect(loose.rules.first?.max == nil)
        let exact = LineParseService.validated(parse, line: "Progesterone AM and PM exactly 10 hours apart")
        #expect(exact.rules.first?.max == 600)
    }
}
