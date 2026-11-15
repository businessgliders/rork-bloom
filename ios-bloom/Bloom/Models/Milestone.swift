import SwiftUI

/// Milestone category. Raw values match the backend enum (except `suggested`,
/// which is expressed with the `isSuggested` flag on the model).
enum MilestoneType: String, Codable, CaseIterable, Identifiable {
    case scan
    case doctorVisit = "doctor_visit"
    case test
    case personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: "Scan"
        case .doctorVisit: "Doctor visit"
        case .test: "Test"
        case .personal: "Personal moment"
        }
    }

    var symbol: String {
        switch self {
        case .scan: "waveform.path.ecg"
        case .doctorVisit: "stethoscope"
        case .test: "testtube.2"
        case .personal: "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .scan: Theme.blush
        case .doctorVisit: Theme.sage
        case .test: Theme.peach
        case .personal: Theme.coral
        }
    }

    var soft: Color {
        switch self {
        case .scan: Theme.blushSoft
        case .doctorVisit: Theme.sageSoft
        case .test: Theme.peachSoft
        case .personal: Theme.coralSoft
        }
    }
}

struct Milestone: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var type: MilestoneType
    var date: Date
    var hasTime: Bool = false
    var notes: String = ""
    var photoFilename: String?
    var isSuggested: Bool = false
    /// Key for a typical suggestion so it can be re-dated when the due date changes.
    var suggestionKey: String?
    /// Typical window, e.g. "Wk 24–28", shown for suggestions.
    var windowLabel: String?
    /// True once the user edited a suggestion; it then keeps its own date.
    var userEdited: Bool = false
    /// Marks lifecycle markers (trimester changes, full term).
    var isMarker: Bool = false
    var createdBy: String?
    /// Path of the uploaded photo in `milestone-photos` (`{pregnancy_id}/{photoFilename}`).
    var photoPath: String?
    /// Kept from the backend `completed` column.
    var completed: Bool?

    func isPast(_ now: Date = .now) -> Bool {
        if hasTime { return date < now }
        return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now)
    }
}
