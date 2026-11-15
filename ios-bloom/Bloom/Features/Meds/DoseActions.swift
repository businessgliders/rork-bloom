import SwiftUI

/// Actions a dose row can trigger.
struct DoseActions {
    /// Logs the dose as taken at the given moment.
    var taken: (DoseInstance, Date) -> Void
    var skip: (DoseInstance) -> Void
    /// Clears the log. Asks first when it was logged more than 10 minutes ago.
    var undo: (DoseInstance) -> Void
    /// Corrects the taken time of a taken dose without undoing it.
    var changeTaken: (DoseInstance, Date) -> Void
    var edit: (Medication) -> Void
}
