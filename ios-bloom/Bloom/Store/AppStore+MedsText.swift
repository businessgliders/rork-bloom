import Foundation

/// "Your meds & rules": the text she types is the only place meds are added, changed or removed.
extension AppStore {
    /// Her text exactly as typed; before she has typed anything, rebuilt from the rules she already has.
    func medsTextOrFallback(for owner: MedOwner) -> String {
        if let saved = medsText[owner] { return saved }
        return fallbackMedsText(for: owner)
    }

    /// Saved as typed, separately from applying (the plan changes only on "Update plan").
    func saveMedsText(_ text: String, for owner: MedOwner) {
        guard medsText[owner] != text else { return }
        medsText[owner] = text
        save()
    }

    /// One line per rule's own words (in order, no repeats), then one line per medication with no rule.
    func fallbackMedsText(for owner: MedOwner) -> String {
        var lines: [String] = []
        var covered = Set<UUID>()
        for rule in rules(for: owner) {
            covered.insert(rule.subjectID)
            if let t = rule.targetMedicationID { covered.insert(t) }
            let line = rule.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        for med in currentMedications(for: owner) where !covered.contains(med.id) {
            lines.append(med.dose.isEmpty ? med.shortName : "\(med.shortName) \(med.dose)")
        }
        return lines.joined(separator: "\n")
    }

    /// Medications she takes now (paused ones included, so their names still match), in her text's order.
    func currentMedications(for owner: MedOwner) -> [Medication] {
        let today = PregnancyMath.calendar.startOfDay(for: now)
        return medications.filter {
            $0.owner == owner && ($0.paused || ($0.endDate.map { PregnancyMath.calendar.startOfDay(for: $0) >= today } ?? true))
        }
        .sorted { ($0.textOrder ?? Int.max, $0.createdAt) < ($1.textOrder ?? Int.max, $1.createdAt) }
    }

    func existingForAssembler(_ owner: MedOwner) -> [RegimenAssembler.Existing] {
        currentMedications(for: owner).map { .init(id: $0.id, name: $0.name, friendlyName: $0.friendlyName) }
    }

    /// Names offered above the keyboard and sent to the AI as "Known".
    func knownMedNames(_ owner: MedOwner) -> [String] {
        var out: [String] = []
        for med in currentMedications(for: owner) {
            for n in [med.shortName, med.name] where !n.isEmpty && !out.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                out.append(n)
            }
        }
        return out
    }

    /// How many medications and rules would change if this were applied. 0 = the plan already matches.
    func pendingChangeCount(_ owner: MedOwner, assembled: RegimenAssembler.Result) -> Int {
        let current = currentMedications(for: owner)
        let currentIDs = Set(current.map(\.id))
        var count = 0
        // New or removed medications; dose changes.
        for draft in assembled.drafts {
            guard let id = draft.existingID, let med = current.first(where: { $0.id == id }) else { count += 1; continue }
            if !draft.dose.isEmpty, draft.dose != med.dose { count += 1 }
        }
        let kept = Set(assembled.drafts.compactMap(\.existingID))
        count += currentIDs.subtracting(kept).count

        // Rules compared by meaning (names, not ids).
        func signature(_ r: ScheduleRule, name: (UUID) -> String) -> String {
            [name(r.subjectID), r.relation.rawValue, r.target.rawValue, r.targetMedicationID.map(name) ?? "",
             (r.targetMeal ?? "").lowercased(), r.minMinutes.map(String.init) ?? "", r.maxMinutes.map(String.init) ?? ""]
                .joined(separator: "|")
        }
        let currentNames = Dictionary(current.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
        let draftNames = Dictionary(assembled.drafts.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
        let old = Set(rules(for: owner).map { signature($0) { currentNames[$0] ?? "?" } })
        let new = Set(assembled.rules.map { signature($0) { draftNames[$0] ?? "?" } })
        count += old.symmetricDifference(new).count

        // Same meds and rules, different order in her text.
        if count == 0 {
            for (index, draft) in assembled.drafts.enumerated() {
                if let id = draft.existingID, current.first(where: { $0.id == id })?.textOrder != index { return 1 }
            }
        }
        return count
    }

    /// Applies her text: meds and rules from the assembled lines, removed lines stop their meds,
    /// and the order she named them becomes the same-time order everywhere.
    @discardableResult
    func applyText(_ owner: MedOwner, text: String, assembled: RegimenAssembler.Result, confirmed: Bool) -> [RuleViolation] {
        medsText[owner] = text
        let found = applyRegimen(owner: owner, meds: assembled.drafts, rules: assembled.rules, confirmed: confirmed)
        let today = PregnancyMath.calendar.startOfDay(for: now)
        for (index, draft) in assembled.drafts.enumerated() {
            let match: Int?
            if let id = draft.existingID {
                match = medications.firstIndex { $0.id == id }
            } else {
                match = medications.lastIndex {
                    $0.owner == owner && $0.managed && $0.name == draft.name
                        && ($0.endDate.map { PregnancyMath.calendar.startOfDay(for: $0) >= today } ?? true)
                }
            }
            if let i = match, medications[i].textOrder != index {
                medications[i].textOrder = index
                enqueue(.medication, medications[i].id.uuidString)
            }
        }
        saveAndReschedule()
        return found
    }

    /// "Who takes it": the medication and the lines that name it move to the other person's text,
    /// so both texts keep describing both plans. Returns the lines that moved.
    @discardableResult
    func moveMedication(_ id: UUID, to newOwner: MedOwner) -> [String] {
        guard let i = medications.firstIndex(where: { $0.id == id }) else { return [] }
        let oldOwner = medications[i].owner
        guard oldOwner != newOwner else { return [] }
        let names = [medications[i].name, medications[i].friendlyName].filter { !$0.isEmpty }.map { $0.lowercased() }
        func mentions(_ line: String) -> Bool {
            let words = Set(line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init))
            return names.contains { n in n.contains(" ") ? line.lowercased().contains(n) : words.contains(n) }
        }
        var oldLines = medsTextOrFallback(for: oldOwner).components(separatedBy: .newlines)
        let moving = oldLines.filter(mentions)
        oldLines.removeAll(where: mentions)
        medsText[oldOwner] = oldLines.joined(separator: "\n")
        let existing = medsTextOrFallback(for: newOwner).trimmingCharacters(in: .whitespacesAndNewlines)
        let added = moving.isEmpty ? [medications[i].shortName] : moving
        medsText[newOwner] = ([existing].filter { !$0.isEmpty } + added).joined(separator: "\n")

        medications[i].owner = newOwner
        medications[i].takerID = isShared ? memberID(for: newOwner) : nil
        for old in rules where old.involves(id) { enqueue(.rule, old.id.uuidString) }
        rules.removeAll { $0.involves(id) }
        enqueue(.medication, id.uuidString)
        saveAndReschedule()
        return added
    }
}
