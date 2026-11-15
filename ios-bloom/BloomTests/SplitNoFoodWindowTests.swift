//
//  SplitNoFoodWindowTests.swift
//  BloomTests
//

import Foundation
import Testing
@testable import Bloom

/// Each medication's no-food window shows as a "before" row and an "after" row around the dose.
/// Rows merge only where different medications overlap.
@MainActor
struct SplitNoFoodWindowTests {
    let cal = PregnancyMath.calendar
    var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14))! }

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
    }

    func med(_ name: String, before: Int, after: Int) -> Medication {
        Medication(name: name, dose: "1 tablet", foodRule: .emptyStomach,
                   noFoodBeforeMinutes: before, noFoodAfterMinutes: after)
    }

    func dose(_ m: Medication, _ hour: Int, _ minute: Int = 0, takenAt: Date? = nil) -> DoseInstance {
        let scheduled = at(hour, minute)
        let log = takenAt.map { DoseLog(medicationID: m.id, scheduledAt: scheduled, status: .taken, takenAt: $0) }
        return DoseInstance(medication: m, scheduledAt: scheduled, log: log)
    }

    @Test func oneMedicationGivesABeforeAndAnAfterRow() {
        let iron = med("Iron", before: 120, after: 60)
        let windows = MedsEngine.noFoodWindows(for: [dose(iron, 15)])
        #expect(windows.count == 2)
        #expect(windows[0].part == .before)
        #expect(windows[0].start == at(13) && windows[0].end == at(15))
        #expect(windows[0].title == "No food · before Iron")
        #expect(windows[1].part == .after)
        #expect(windows[1].start == at(15) && windows[1].end == at(16))
        #expect(windows[1].title == "No food · after Iron")
        #expect(windows[0].id != windows[1].id)
    }

    @Test func afterRowCountsFromTheTakenTime() {
        let iron = med("Iron", before: 120, after: 60)
        let windows = MedsEngine.noFoodWindows(for: [dose(iron, 15, takenAt: at(15, 10))])
        let after = windows.first { $0.part == .after }
        #expect(after?.start == at(15, 10))
        #expect(after?.end == at(16, 10))
        #expect(after?.isConfirmed == true)
    }

    @Test func overlappingMedicationsMergeIntoOneRow() {
        let thyroid = med("Thyroid", before: 0, after: 60)
        let iron = med("Iron", before: 60, after: 60)
        // Thyroid after 7:00–8:00 overlaps Iron before 7:30–8:30.
        let windows = MedsEngine.noFoodWindows(for: [dose(thyroid, 7), dose(iron, 8, 30)])
        #expect(windows.count == 2)
        #expect(windows[0].part == .combined)
        #expect(windows[0].title == "No food · Iron & Thyroid")
        #expect(windows[0].start == at(7) && windows[0].end == at(8, 30))
        // Iron's after part only touches the merged block, so it stays its own row.
        #expect(windows[1].title == "No food · after Iron")
        #expect(windows[1].start == at(8, 30) && windows[1].end == at(9, 30))
    }

    @Test func noFoodOKRowBetweenBeforeAndAfter() {
        let iron = med("Iron", before: 60, after: 60)
        let timeline = MedsEngine.timeline(for: [dose(iron, 11)])
        let foodOK = timeline.filter { if case .foodOK = $0 { return true }; return false }
        #expect(foodOK.count == 1)
    }
}
