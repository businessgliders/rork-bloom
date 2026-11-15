//
//  MedsTextAndCycleTests.swift
//  BloomTests
//

import Foundation
import Testing
@testable import Bloom

/// "Progesterone AM and Progesterone PM at least 10 hours apart", with PM at bedtime.
/// Gap rules must hold across midnight, using each day's actual routine.
struct CrossMidnightTests {
    let am = UUID()
    let pm = UUID()

    var meds: [EngineMed] { [EngineMed(id: am, name: "Progesterone AM"), EngineMed(id: pm, name: "Progesterone PM")] }

    var rules: [ScheduleRule] {
        [
            ScheduleRule(subjectID: pm, relation: .at, target: .bed, minMinutes: 0),
            ScheduleRule(subjectID: am, relation: .apart, target: .medication, targetMedicationID: pm, minMinutes: 600),
        ]
    }

    func routine(_ name: String, days: Set<Int>, wake: Int, bed: Int) -> ScheduleTemplate {
        ScheduleTemplate(name: name, days: days, wake: DoseTime(minutes: wake), bed: DoseTime(minutes: bed), meals: [
            ScheduleMeal(name: "Breakfast", time: DoseTime(minutes: wake + 30)),
            ScheduleMeal(name: "Lunch", time: DoseTime(minutes: 12 * 60 + 30)),
            ScheduleMeal(name: "Dinner", time: DoseTime(minutes: 18 * 60 + 30)),
        ])
    }

    func minutes(_ template: ScheduleTemplate, _ id: UUID) -> Int? {
        template.dose(for: id)?.time.minutesFromMidnight
    }

    @Test func gapHoldsAcrossMidnight() {
        // PM at 10:30 PM with a 10 h gap: the next morning's AM can't be before 8:30.
        let every = routine("Every day", days: Set(0...6), wake: 7 * 60, bed: 22 * 60 + 30)
        let (placed, violations) = ScheduleCycle.generateAll([every], meds: { _ in meds }, rules: { _ in rules })
        #expect(minutes(placed[0], pm) == 22 * 60 + 30)
        #expect(minutes(placed[0], am) == 8 * 60 + 30)
        #expect(violations[every.id]?.isEmpty == true)
    }

    @Test func lateDoseMovesTheNextMorning() {
        // PM taken at 11:15 PM instead of 10:30 PM: tomorrow's AM moves from 8:30 to 9:15.
        let times = [am: 8 * 60 + 30, pm: 22 * 60 + 30]
        let next = ScheduleCycle.handover(times: times, previous: [pm: 23 * 60 + 15], wake: 7 * 60, bed: 22 * 60 + 30,
                                          meals: [], meds: meds, rules: rules)
        #expect(next[am] == 9 * 60 + 15)
        #expect(next[pm] == 22 * 60 + 30)
    }

    @Test func onTimeDoseLeavesTheMorningAlone() {
        let times = [am: 8 * 60 + 30, pm: 22 * 60 + 30]
        let next = ScheduleCycle.handover(times: times, previous: [pm: 22 * 60 + 30], wake: 7 * 60, bed: 22 * 60 + 30,
                                          meals: [], meds: meds, rules: rules)
        #expect(next == times)
    }

    @Test func weekendToWeekdayHandover() {
        // Weekend bed 11:30 PM → Sunday's PM at 11:30 PM, so Monday's AM settles at 9:30.
        // Tuesday–Friday follow Weekdays nights and keep 8:30.
        let weekdays = routine("Weekdays", days: Set(1...5), wake: 7 * 60, bed: 22 * 60 + 30)
        let weekend = routine("Weekend", days: [0, 6], wake: 8 * 60 + 30, bed: 23 * 60 + 30)
        let (placed, _) = ScheduleCycle.generateAll([weekdays, weekend], meds: { _ in meds }, rules: { _ in rules })
        let wd = placed.first { $0.id == weekdays.id }!
        let we = placed.first { $0.id == weekend.id }!
        #expect(minutes(wd, am) == 8 * 60 + 30)
        #expect(minutes(we, pm) == 23 * 60 + 30)

        let monday = ScheduleCycle.handover(
            times: [am: minutes(wd, am)!, pm: minutes(wd, pm)!],
            previous: [pm: minutes(we, pm)!],
            wake: 7 * 60, bed: 22 * 60 + 30, meals: [], meds: meds, rules: rules)
        #expect(monday[am] == 9 * 60 + 30)
        #expect(minutes(wd, am) == 8 * 60 + 30)
    }
}

/// Doses at the same time follow the order they first appear in her text.
struct SameTimeOrderTests {
    @Test func sameTimeFollowsTextOrder() {
        let day = PregnancyMath.calendar.startOfDay(for: .now)
        let start = PregnancyMath.calendar.date(byAdding: .day, value: -3, to: day)!
        func med(_ name: String, order: Int) -> Medication {
            var m = Medication(name: name, dose: "")
            m.times = [DoseTime(hour: 8, minute: 0)]
            m.startDate = start
            m.textOrder = order
            return m
        }
        // Stored alphabetically; her text names Thyroid, then Prenatal, then Calcium.
        let meds = [med("Calcium", order: 2), med("Prenatal", order: 1), med("Thyroid", order: 0)]
        let names = MedsEngine.instances(on: day, medications: meds, logs: []).map(\.medication.name)
        #expect(names == ["Thyroid", "Prenatal", "Calcium"])
    }
}

/// One line at a time: editing one line re-reads only that line.
@MainActor
struct LineParserTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func record(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    @Test func editingOneLineReParsesOnlyThatLine() async {
        let counter = Counter()
        let parser = LineParser(transport: { line, _, _ in
            counter.record(line)
            return #"{"meds":[{"name":"\#(line.split(separator: " ").first ?? "Med")"}],"rules":[]}"#
        }, defaults: nil)

        let text = """
        Thyroid as soon as I wake up, no food for 30 min after.
        Iron 4 hours after Thyroid.
        Prenatal AM with lunch.
        """
        await parser.parse(lines: RegimenAssembler.lines(of: text), known: [])
        #expect(parser.callCount == 3)

        let edited = text.replacingOccurrences(of: "Iron 4 hours", with: "Iron 5 hours")
        await parser.parse(lines: RegimenAssembler.lines(of: edited), known: [])
        #expect(parser.callCount == 4)
        #expect(counter.seen.last == "Iron 5 hours after Thyroid.")
        #expect(parser.isUpToDate(RegimenAssembler.lines(of: edited)))
    }

    @Test func unchangedTextSendsNothing() async {
        let parser = LineParser(transport: { _, _, _ in #"{"meds":[{"name":"Iron"}],"rules":[]}"# }, defaults: nil)
        let lines = ["Iron with dinner."]
        await parser.parse(lines: lines, known: [])
        await parser.parse(lines: ["  Iron   with dinner. "], known: ["Iron"])
        #expect(parser.callCount == 1)
    }

    @Test func oneRetryThenMarksTheLine() async {
        let counter = Counter()
        let parser = LineParser(transport: { _, _, attempt in
            counter.record("\(attempt)")
            throw LineParseError.unreadable
        }, defaults: nil)
        await parser.parse(lines: ["Iron with dinner."], known: [])
        #expect(counter.seen == ["0", "1"])
        #expect(parser.failed["Iron with dinner."] != nil)
        #expect(parser.cached("Iron with dinner.") == nil)
    }

    @Test func assemblerKeepsFirstMentionOrderAndDedupes() {
        let text = """
        Thyroid as soon as I wake up.
        Iron 4 hours after Thyroid.
        Keep iron and calcium 2 hours apart.
        """
        let parses: [String: LineParse] = [
            "Thyroid as soon as I wake up.": LineParse(meds: [.init(name: "Thyroid")],
                                                        rules: [.init(subject: "Thyroid", relation: "at", targetType: "wake", target: nil, min: 0, max: nil)]),
            "Iron 4 hours after Thyroid.": LineParse(meds: [.init(name: "Iron"), .init(name: "Thyroid")],
                                                      rules: [.init(subject: "Iron", relation: "after", targetType: "medication", target: "Thyroid", min: 240, max: nil)]),
            "Keep iron and calcium 2 hours apart.": LineParse(meds: [.init(name: "iron"), .init(name: "calcium")],
                                                               rules: [.init(subject: "iron", relation: "apart", targetType: "medication", target: "calcium", min: 120, max: nil)]),
        ]
        let result = RegimenAssembler.assemble(text: text, parses: parses, existing: [])
        #expect(result.drafts.map(\.name) == ["Thyroid", "Iron", "Calcium"])
        #expect(result.drafts.map { result.order[$0.id] } == [0, 1, 2])
        #expect(result.rules.count == 3)
        #expect(result.lines.map(\.index) == [0, 1, 2])
    }

    @Test func withAnotherMedKeepsTheRule() {
        let text = "Calcium with Prenatal AM"
        let parses: [String: LineParse] = [
            "Calcium with Prenatal AM": LineParse(meds: [.init(name: "Calcium"), .init(name: "Prenatal AM")],
                                                   rules: [.init(subject: "Calcium", relation: "with", targetType: "medication", target: "Prenatal AM", min: 0, max: nil)]),
        ]
        let result = RegimenAssembler.assemble(text: text, parses: parses, existing: [])
        #expect(result.rules.count == 1)
        #expect(result.rules.first?.relation == .with)
        #expect(result.rules.first?.targetMedicationID == result.drafts.first { $0.name == "Prenatal AM" }?.id)
    }
}
