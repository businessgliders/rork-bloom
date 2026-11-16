//
//  MedsTextAndCycleTests.swift
//  CarryTests
//

import Foundation
import Testing
@testable import Carry

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
        let parser = LineParser(transport: { line, _, _, _ in
            counter.record(line)
            let name = line.split(separator: " ").first.map(String.init) ?? "Med"
            return #"{"meds":[{"name":"\#(name)"}],"rules":[{"subject":"\#(name)","relation":"with","targetType":"food"}]}"#
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
        let parser = LineParser(transport: { _, _, _, _ in #"{"meds":[{"name":"Iron"}],"rules":[{"subject":"Iron","relation":"with","targetType":"meal","target":"dinner"}]}"# }, defaults: nil)
        let lines = ["Iron with dinner."]
        await parser.parse(lines: lines, known: [])
        await parser.parse(lines: ["  Iron   with dinner. "], known: ["Iron"])
        #expect(parser.callCount == 1)
    }

    @Test func oneRetryThenMarksTheLine() async {
        let counter = Counter()
        let parser = LineParser(transport: { _, _, _, attempt in
            counter.record("\(attempt)")
            throw LineParseError.unreadable
        }, defaults: nil)
        await parser.parse(lines: ["Iron with dinner."], known: [])
        #expect(counter.seen == ["0", "1"])
        #expect(parser.failed["Iron with dinner."] != nil)
        #expect(parser.cached("Iron with dinner.") == nil)
    }

    /// Her text (reconstructed from the lines she reported; her saved copy lives only on her phone).
    static let herText = """
    Thyroid first thing in the morning
    30 minutes afterwards I can't have any food

    Progesterone a.m.
    approximately 10 to 12 hours apart from progesterone p.m.

    Iron
    at least four hours after taking the thyroid
    cannot have food two hours before
    or 1 hour afterwards

    Prenatal vitamin
    within one hour after my dinner
    """

    /// A fake model that reads like the real one: a line naming no medication comes back "needsContext"
    /// unless Context names one, and then it uses that medication as the subject.
    nonisolated static func fakeModel(line: String, context: [String]) -> String {
        let names = ["Thyroid": "Thyroid", "Progesterone a.m.": "Progesterone AM", "Iron": "Iron",
                     "Prenatal vitamin": "Prenatal vitamin"]
        let subject = context.first.flatMap { first in names.first { first.hasPrefix($0.key) }?.value }
        func ctx(_ rule: String, extraMeds: String = "") -> String {
            guard let subject else { return #"{"meds":[\#(extraMeds)],"rules":[],"needsContext":true}"# }
            let meds = #"{"name":"\#(subject)"}"# + (extraMeds.isEmpty ? "" : "," + extraMeds)
            return #"{"meds":[\#(meds)],"rules":[\#(rule.replacingOccurrences(of: "$S", with: subject))]}"#
        }
        switch line {
        case "Thyroid first thing in the morning":
            return #"{"meds":[{"name":"Thyroid"}],"rules":[{"subject":"Thyroid","relation":"at","targetType":"wake","min":0}]}"#
        case "Progesterone a.m.": return #"{"meds":[{"name":"Progesterone AM"}],"rules":[]}"#
        case "Iron": return #"{"meds":[{"name":"Iron"}],"rules":[]}"#
        case "Prenatal vitamin": return #"{"meds":[{"name":"Prenatal vitamin"}],"rules":[]}"#
        case "30 minutes afterwards I can't have any food":
            return ctx(#"{"subject":"$S","relation":"before","targetType":"food","min":30}"#)
        case "approximately 10 to 12 hours apart from progesterone p.m.":
            return ctx(#"{"subject":"$S","relation":"apart","targetType":"medication","target":"Progesterone PM","min":600,"max":720}"#,
                       extraMeds: #"{"name":"Progesterone PM"}"#)
        case "at least four hours after taking the thyroid":
            return ctx(#"{"subject":"$S","relation":"after","targetType":"medication","target":"Thyroid","min":240}"#,
                       extraMeds: #"{"name":"Thyroid"}"#)
        case "cannot have food two hours before":
            return ctx(#"{"subject":"$S","relation":"after","targetType":"food","min":120}"#)
        case "or 1 hour afterwards":
            return ctx(#"{"subject":"$S","relation":"before","targetType":"food","min":60}"#)
        case "within one hour after my dinner":
            return ctx(#"{"subject":"$S","relation":"after","targetType":"meal","target":"dinner","min":0,"max":60}"#)
        default: return #"{"meds":[],"rules":[]}"#
        }
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, [String])] = []
        func record(_ line: String, _ context: [String]) { lock.lock(); items.append((line, context)); lock.unlock() }
        var all: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test func followOnLinesBorrowTheMedicationAbove() async {
        let log = Log()
        let parser = LineParser(transport: { line, context, _, _ in
            log.record(line, context)
            return Self.fakeModel(line: line, context: context)
        }, defaults: nil)
        let lines = RegimenAssembler.lines(of: Self.herText)
        await parser.parse(lines: lines, known: [])

        // 10 lines read alone, then the 6 follow-on lines with context.
        #expect(parser.callCount == 16)
        let withContext = Dictionary(log.all.filter { !$0.1.isEmpty }.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        #expect(withContext["30 minutes afterwards I can't have any food"] == ["Thyroid first thing in the morning"])
        #expect(withContext["approximately 10 to 12 hours apart from progesterone p.m."] == ["Progesterone a.m."])
        #expect(withContext["at least four hours after taking the thyroid"] == ["Iron"])
        #expect(withContext["cannot have food two hours before"] == ["Iron", "at least four hours after taking the thyroid"])
        #expect(withContext["or 1 hour afterwards"] == ["Iron", "at least four hours after taking the thyroid", "cannot have food two hours before"])
        #expect(withContext["within one hour after my dinner"] == ["Prenatal vitamin"])
        #expect(parser.isUpToDate(lines))

        // Every line maps to a medication, and every follow-on line to a rule.
        let result = RegimenAssembler.assemble(text: Self.herText, lineParses: parser.resolved(lines), existing: [])
        let names = Set(result.drafts.map(\.name))
        #expect(names == ["Thyroid", "Progesterone AM", "Progesterone PM", "Iron", "Prenatal vitamin"])
        for summary in result.lines {
            #expect(summary.problem == nil, "line \(summary.index): \(summary.text)")
            #expect(!summary.medIDs.isEmpty, "line \(summary.index): \(summary.text)")
        }
        let ruleLines = [0, 1, 4, 7, 8, 9, 12]
        for i in ruleLines {
            #expect(result.lines.first { $0.index == i }?.ruleIDs.isEmpty == false, "line \(i) has no rule")
        }
        #expect(result.rules.count == 7)
        let iron = result.drafts.first { $0.name == "Iron" }!.id
        #expect(result.rules.filter { $0.subjectID == iron }.count == 3)
    }

    @Test func namesLoseTheAndMy() throws {
        let p = try LineParseService.decode(#"{"meds":[{"name":"Iron"},{"name":"the thyroid"}],"rules":[{"subject":"Iron","relation":"after","targetType":"medication","target":"the thyroid","min":240}]}"#)
        #expect(p.meds.map(\.name) == ["Iron", "thyroid"])
        #expect(p.rules.first?.target == "thyroid")
    }

    @Test func timeOfDayStaysPartOfTheName() throws {
        #expect(LineParseService.canonicalTimeOfDay("Progesterone a.m.") == "Progesterone AM")
        #expect(LineParseService.canonicalTimeOfDay("progesterone p.m.") == "progesterone PM")
        #expect(LineParseService.canonicalTimeOfDay("Prenatal pm") == "Prenatal PM")
        #expect(LineParseService.canonicalTimeOfDay("Clonazepam") == "Clonazepam")
        let dropped = try LineParseService.decode(#"{"meds":[{"name":"Progesterone"}],"rules":[]}"#)
        let fixed = LineParseService.restoreTimeOfDay(dropped, line: "Progesterone a.m.")
        #expect(fixed.meds.map(\.name) == ["Progesterone AM"])
        // Both written: leave the model's names alone.
        let both = LineParseService.restoreTimeOfDay(dropped, line: "Progesterone a.m. and progesterone p.m. 10 h apart")
        #expect(both.meds.map(\.name) == ["Progesterone"])
    }

    /// What the fallback model actually returned for her lines read alone (2026-11-15).
    @Test func guessedSubjectsAreDropped() throws {
        let thyroid = try LineParseService.decode(#"{"meds":[{"name":"thyroid"}],"rules":[{"subject":"thyroid","relation":"after","targetType":"medication","target":"thyroid","min":240}],"needsContext":false}"#)
        #expect(LineParseService.validated(thyroid, line: "at least four hours after taking the thyroid").rules.isEmpty)
        let asTarget = try LineParseService.decode(#"{"meds":[{"name":"Thyroid"}],"rules":[{"subject":"Thyroid","relation":"after","targetType":"food","min":240}]}"#)
        #expect(LineParseService.validated(asTarget, line: "at least four hours after taking the thyroid").rules.isEmpty)
        let apart = try LineParseService.decode(#"{"meds":[{"name":"progesterone p.m."}],"rules":[{"subject":"progesterone p.m.","relation":"apart","targetType":"medication","min":600,"max":720}]}"#)
        #expect(LineParseService.validated(apart, line: "approximately 10 to 12 hours apart from progesterone p.m.").rules.isEmpty)
        // Real subjects stay.
        let iron = try LineParseService.decode(#"{"meds":[{"name":"Iron"},{"name":"Thyroid"}],"rules":[{"subject":"Iron","relation":"after","targetType":"medication","target":"Thyroid","min":240}]}"#)
        #expect(LineParseService.validated(iron, line: "Iron 4 hours after Thyroid.").rules.count == 1)
        let ctx = try LineParseService.decode(#"{"meds":[{"name":"Iron"},{"name":"thyroid"}],"rules":[{"subject":"Iron","relation":"after","targetType":"medication","target":"thyroid","min":240}]}"#)
        #expect(LineParseService.validated(ctx, line: "at least four hours after taking the thyroid").rules.count == 1)
        let thyroidWake = try LineParseService.decode(#"{"meds":[{"name":"Thyroid"}],"rules":[{"subject":"Thyroid","relation":"before","targetType":"food","min":30}]}"#)
        #expect(LineParseService.validated(thyroidWake, line: "Thyroid as soon as I wake up, no food for 30 min after.").rules.count == 1)
    }

    /// DeepSeek's real reply for the 10–12 h line with "Progesterone a.m." as context: turned round.
    @Test func apartRuleTurnedRoundIsKept() throws {
        let p = try LineParseService.decode(#"{"meds":[{"name":"progesterone p.m."}],"rules":[{"subject":"progesterone p.m.","relation":"apart","targetType":"medication","target":"progesterone a.m.","min":600,"max":720}],"needsContext":false}"#)
        let v = LineParseService.validated(p, line: "approximately 10 to 12 hours apart from progesterone p.m.")
        #expect(v.rules.count == 1)
        #expect(v.rules.first?.subject == "progesterone AM")
        #expect(v.rules.first?.target == "progesterone PM")
        #expect(v.meds.contains { $0.name == "progesterone AM" })
    }

    /// DeepSeek's real reply when it dropped a.m./p.m. on both sides.
    @Test func timeOfDayComesBackFromContext() throws {
        let p = try LineParseService.decode(#"{"meds":[{"name":"progesterone"}],"rules":[{"subject":"progesterone","relation":"apart","targetType":"medication","target":"progesterone","min":600,"max":720}],"needsContext":false}"#)
        let line = "approximately 10 to 12 hours apart from progesterone p.m."
        let fixed = LineParseService.validated(LineParseService.restoreTimeOfDay(p, line: line, context: ["Progesterone a.m."]), line: line)
        #expect(fixed.rules.count == 1)
        #expect(fixed.rules.first?.subject == "progesterone AM")
        #expect(fixed.rules.first?.target == "progesterone PM")
        #expect(Set(fixed.meds.map(\.name)) == ["progesterone AM", "progesterone PM"])
    }

    @Test func apartRangeIsCheckedAndDescribed() {
        let am = UUID(), pm = UUID()
        let rule = ScheduleRule(subjectID: am, relation: .apart, target: .medication, minMinutes: 600, maxMinutes: 720,
                                sourceText: "")
        var r = rule; r.targetMedicationID = pm
        #expect(ScheduleEngine.describe(r, names: [am: "Progesterone AM", pm: "Progesterone PM"])
                .contains("10 h–12 h apart from Progesterone PM") || ScheduleEngine.describe(r, names: [am: "Progesterone AM", pm: "Progesterone PM"])
                .contains("apart from Progesterone PM"))
        let routine = EngineRoutine(wake: 7 * 60, bed: 23 * 60, meals: [])
        #expect(ScheduleEngine.deficit(r, times: [am: 7 * 60, pm: 18 * 60], routine: routine) == 0)
        #expect(ScheduleEngine.deficit(r, times: [am: 7 * 60, pm: 15 * 60], routine: routine) == 120)
    }

    @Test func contextReadWithNoRuleAsksTheFallback() async {
        let parser = LineParser(transport: { line, context, _, attempt in
            if !context.isEmpty, attempt == 0 { return #"{"meds":[{"name":"thyroid"}],"rules":[],"needsContext":true}"# }
            return Self.fakeModel(line: line, context: context)
        }, defaults: nil)
        let text = "Iron\nat least four hours after taking the thyroid"
        let lines = RegimenAssembler.lines(of: text)
        await parser.parse(lines: lines, known: [])
        #expect(parser.resolved(lines)[1]?.rules.first?.subject == "Iron")
    }

    /// End to end with the bad alone-reads: the follow-on lines still borrow Iron, not Thyroid.
    @Test func badAloneReadsStillBorrowTheRightMedication() async {
        let parser = LineParser(transport: { line, context, _, _ in
            if context.isEmpty, line == "at least four hours after taking the thyroid" {
                return #"{"meds":[{"name":"thyroid"}],"rules":[{"subject":"thyroid","relation":"after","targetType":"medication","target":"thyroid","min":240}],"needsContext":false}"#
            }
            if context.isEmpty, line.hasPrefix("approximately") {
                return #"{"meds":[{"name":"progesterone p.m."}],"rules":[{"subject":"progesterone p.m.","relation":"apart","targetType":"medication","min":600,"max":720}],"needsContext":false}"#
            }
            return Self.fakeModel(line: line, context: context)
        }, defaults: nil)
        let lines = RegimenAssembler.lines(of: Self.herText)
        await parser.parse(lines: lines, known: [])
        let result = RegimenAssembler.assemble(text: Self.herText, lineParses: parser.resolved(lines), existing: [])
        #expect(result.lines.allSatisfy { $0.problem == nil })
        let iron = result.drafts.first { $0.name == "Iron" }!.id
        #expect(result.rules.filter { $0.subjectID == iron }.count == 3)
        #expect(result.rules.count == 7)
    }

    @Test func blankLineIsABreak() async {
        let parser = LineParser(transport: { line, context, _, _ in Self.fakeModel(line: line, context: context) }, defaults: nil)
        let text = "Thyroid first thing in the morning\n\n30 minutes afterwards I can't have any food"
        let lines = RegimenAssembler.lines(of: text)
        await parser.parse(lines: lines, known: [])
        #expect(parser.callCount == 2)
        let result = RegimenAssembler.assemble(text: text, lineParses: parser.resolved(lines), existing: [])
        #expect(result.lines.first { $0.index == 2 }?.problem != nil)
    }

    @Test func editingTheMedicationLineRereadsTheLinesUnderIt() async {
        let log = Log()
        let parser = LineParser(transport: { line, context, _, _ in
            log.record(line, context)
            return Self.fakeModel(line: line.replacingOccurrences(of: "Iron tablet", with: "Iron"), context: context.map {
                $0 == "Iron tablet" ? "Iron" : $0 })
        }, defaults: nil)
        let text = "Iron\nat least four hours after taking the thyroid\nThyroid first thing in the morning"
        await parser.parse(lines: RegimenAssembler.lines(of: text), known: [])
        let before = parser.callCount
        let edited = text.replacingOccurrences(of: "Iron\n", with: "Iron tablet\n")
        await parser.parse(lines: RegimenAssembler.lines(of: edited), known: [])
        // The edited line, then the follow-on line with its new context. The Thyroid line isn't touched.
        #expect(parser.callCount == before + 2)
        #expect(log.all.last?.1 == ["Iron tablet"])
    }

    @Test func withoutBlankLinesTheNearestMedicationWins() async {
        let parser = LineParser(transport: { line, context, _, _ in Self.fakeModel(line: line, context: context) }, defaults: nil)
        let text = Self.herText.replacingOccurrences(of: "\n\n", with: "\n")
        let lines = RegimenAssembler.lines(of: text)
        await parser.parse(lines: lines, known: [])
        let result = RegimenAssembler.assemble(text: text, lineParses: parser.resolved(lines), existing: [])
        #expect(result.lines.allSatisfy { $0.problem == nil })
        #expect(result.rules.count == 7)
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
