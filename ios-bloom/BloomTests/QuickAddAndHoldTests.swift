import Foundation
import Testing
import UIKit
@testable import Bloom

/// Overdue empty-stomach doses never show "Food OK".
@MainActor
struct OverdueHoldTests {
    let cal = PregnancyMath.calendar
    var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14))! }
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
    }

    @Test func overdueEmptyStomachDoseHoldsFood() {
        let m = Medication(name: "Levothyroxine", friendlyName: "Thyroid", dose: "", times: [DoseTime(hour: 7, minute: 0)],
                           foodRule: .emptyStomach, noFoodBeforeMinutes: 30, noFoodAfterMinutes: 30,
                           startDate: cal.date(byAdding: .day, value: -3, to: today)!)
        let instances = MedsEngine.instances(on: today, medications: [m], logs: [])
        let rn = MedsEngine.rightNow(instances: instances, now: at(9, 0))
        guard case .holdForDose(let dose, let emptySince, let delaysTo) = rn.food else {
            Issue.record("Expected hold, got \(rn.food)")
            return
        }
        #expect(dose.medication.id == m.id)
        #expect(emptySince == at(8, 30))
        #expect(delaysTo == at(9, 30))
    }

    @Test func anyTimeDoseStillAllowsFood() {
        let m = Medication(name: "Prenatal", dose: "", times: [DoseTime(hour: 7, minute: 0)],
                           startDate: cal.date(byAdding: .day, value: -3, to: today)!)
        let instances = MedsEngine.instances(on: today, medications: [m], logs: [])
        let rn = MedsEngine.rightNow(instances: instances, now: at(9, 0))
        if case .foodOK = rn.food {} else { Issue.record("Expected food OK, got \(rn.food)") }
    }
}

/// The AI's answer is checked on device: no invented doses, and a missing time triggers a question.
struct MedParseDecodeTests {
    @Test func dropsDoseNotInText() throws {
        let json = #"{"fullName":"Ferrous sulfate","friendlyName":"Iron","emoji":"💊","amount":"1 tablet","strength":"325 mg","schedule":{"type":"daily"},"scheduleStated":true,"times":["08:00"],"timeStated":false,"foodRule":"empty_stomach","foodStated":true,"noFoodBeforeMinutes":0,"noFoodAfterMinutes":30,"minutesStated":false,"followUp":null}"#
        let result = try MedParseService.decode(json, source: "iron every morning on an empty stomach")
        #expect(result.dose.isEmpty)
        #expect(result.followUp != nil)
        #expect(result.suggested.contains(.time))
        #expect(result.suggested.contains(.minutes))
        #expect(result.foodRule == .emptyStomach)
    }

    @Test func keepsStatedDoseAndTime() throws {
        let json = #"{"fullName":"Levothyroxine","friendlyName":"Thyroid","emoji":"🌙","amount":"1 tablet","strength":"75 mcg","schedule":{"type":"daily"},"scheduleStated":true,"times":["06:30"],"timeStated":true,"foodRule":"empty_stomach","foodStated":false,"noFoodBeforeMinutes":0,"noFoodAfterMinutes":30,"minutesStated":false,"followUp":null}"#
        let result = try MedParseService.decode(json, source: "Levothyroxine one tablet 75 mcg at 6:30am")
        #expect(result.dose == "1 tablet, 75 mcg")
        #expect(result.times == [DoseTime(hour: 6, minute: 30)])
        #expect(result.followUp == nil)
        #expect(result.suggested.contains(.food))
    }
}

struct LabelFilterTests {
    @Test func removesPersonalLines() {
        let lines = [
            "CVS Pharmacy #4521",
            "123 Main St, Springfield IL 62704",
            "Patient: Maya Johnson",
            "Rx# 1234567",
            "Dr. Alan Smith",
            "LEVOTHYROXINE 75 MCG TABLET",
            "Take 1 tablet by mouth every morning on an empty stomach",
            "Qty: 30   Refills: 2",
            "Filled 11/02/2026",
            "(555) 123-4567",
        ]
        let result = LabelTextFilter.filter(lines, personalNames: ["Maya"])
        #expect(result.kept == [
            "LEVOTHYROXINE 75 MCG TABLET",
            "Take 1 tablet by mouth every morning on an empty stomach",
        ])
        #expect(result.removedCount == 8)
    }
}

/// Reads a rendered pharmacy label on device and strips personal details.
@MainActor
struct LabelScanOCRTests {
    func renderLabel(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 900, height: 120 + lines.count * 70)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 60 + i * 70), withAttributes: attrs)
            }
        }
    }

    @Test func readsAndFiltersLabel() async throws {
        let image = renderLabel([
            "Patient: Maya Jensen",
            "LEVOTHYROXINE 75 MCG TABLET",
            "Take 1 tablet by mouth every morning",
            "on an empty stomach",
            "Dr. Hansen  Refills: 3",
        ])
        let lines = try await LabelOCR.lines(in: image)
        #expect(lines.count >= 4)
        let filtered = LabelTextFilter.filter(lines, personalNames: ["Maya"])
        let text = filtered.text.lowercased()
        #expect(text.contains("levothyroxine"))
        #expect(text.contains("empty stomach"))
        #expect(!text.contains("maya"))
        #expect(!text.contains("refills"))
    }
}
