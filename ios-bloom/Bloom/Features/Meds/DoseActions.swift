import SwiftUI

/// Actions a dose row can trigger.
struct DoseActions {
    /// Logs the dose as taken at the given moment.
    var taken: (DoseInstance, Date) -> Void
    var skip: (DoseInstance) -> Void
    var undo: (DoseInstance) -> Void
    var edit: (Medication) -> Void
}
