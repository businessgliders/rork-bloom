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
        // After "Delete all my data" the open editor closes and saves; don't write her old text back.
        guard isOnboarded, medsText[owner] != text else { return }
        medsText[owner] = text
        markMedsTextEdited(owner)
        save()
    }

    // MARK: - med_texts sync (latest edit wins)

    private static let stampsKey = "meds.textEditedAt"

    /// When this phone last changed that person's text (kept on this phone only).
    func medsTextEditedAt(_ owner: MedOwner) -> Date? {
        let raw = UserDefaults.standard.dictionary(forKey: Self.stampsKey) as? [String: Double] ?? [:]
        return raw[owner.rawValue].map { Date(timeIntervalSince1970: $0) }
    }

    private func setMedsTextStamp(_ owner: MedOwner, _ date: Date) {
        var raw = UserDefaults.standard.dictionary(forKey: Self.stampsKey) as? [String: Double] ?? [:]
        raw[owner.rawValue] = date.timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: Self.stampsKey)
    }

    /// Records a local edit and queues it for `med_texts`.
    func markMedsTextEdited(_ owner: MedOwner) {
        setMedsTextStamp(owner, .now)
        enqueue(.medText, owner.rawValue)
    }

    /// Takes each remote text that is newer than this phone's last edit. Returns true when a text changed.
    func mergeRemoteMedTexts(_ remote: RemoteState) -> Bool {
        var changed = false
        for row in remote.medTexts {
            guard let role = remote.members.first(where: { $0.userID == row.taker_id })?.role else { continue }
            if hasPendingOp(.medText, role.rawValue) { continue }
            let remoteDate = row.updated_at ?? .distantPast
            if let local = medsTextEditedAt(role), local > remoteDate, medsText[role] != nil { continue }
            if medsText[role] != row.text {
                medsText[role] = row.text
                changed = true
            }
            setMedsTextStamp(role, remoteDate)
        }
        return changed
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
        markMedsTextEdited(owner)
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
        markMedsTextEdited(oldOwner)
        markMedsTextEdited(newOwner)

        medications[i].owner = newOwner
        medications[i].takerID = isShared ? memberID(for: newOwner) : nil
        for old in rules where old.involves(id) { enqueue(.rule, old.id.uuidString) }
        rules.removeAll { $0.involves(id) }
        enqueue(.medication, id.uuidString)
        saveAndReschedule()
        return added
    }

    // MARK: - Medication sheet

    /// "Remove medication": its lines leave her text (with the lines under it that have no other med name),
    /// its rules and planned times go, and it ends from today. Logged history stays.
    func removeMedicationFromPlan(_ id: UUID) {
        guard let i = medications.firstIndex(where: { $0.id == id }) else { return }
        let owner = medications[i].owner
        let names = [medications[i].name, medications[i].friendlyName].filter { !$0.isEmpty }.map { $0.lowercased() }
        let others = currentMedications(for: owner).filter { $0.id != id }
            .flatMap { [$0.name, $0.friendlyName] }.filter { !$0.isEmpty }.map { $0.lowercased() }
        func words(_ line: String) -> [String] {
            line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
        }
        func mentions(_ line: String) -> Bool {
            let set = Set(words(line))
            return names.contains { n in n.contains(" ") ? line.lowercased().contains(n) : set.contains(n) }
        }
        func startsWithOther(_ line: String) -> Bool {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            return others.contains { lower.hasPrefix($0) }
        }
        var kept: [String] = []
        var skipping = false
        for line in medsTextOrFallback(for: owner).components(separatedBy: .newlines) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank {
                skipping = false
                // No double blank lines where a block was taken out.
                if let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                kept.append(line)
            } else if mentions(line), !startsWithOther(line) {
                skipping = true
            } else if skipping, !startsWithOther(line) {
                continue
            } else {
                skipping = false
                kept.append(line)
            }
        }
        while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeFirst() }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        medsText[owner] = kept.joined(separator: "\n")
        markMedsTextEdited(owner)

        let yesterday = PregnancyMath.addDays(-1, to: now)
        medications[i].endDate = max(yesterday, PregnancyMath.calendar.startOfDay(for: medications[i].startDate))
        medications[i].paused = false
        removeFromSchedules(id)
        enqueue(.medication, id.uuidString)
        rebuildPlan()
        saveAndReschedule()
    }

    /// Re-reads and applies each person's text (after a med changed hands).
    func reapplyTexts(_ owners: [MedOwner]) async {
        let parser = LineParser()
        for who in owners {
            let body = medsTextOrFallback(for: who)
            let all = RegimenAssembler.lines(of: body)
            let parsed = await parser.parse(lines: all, known: knownMedNames(who))
            guard parser.isUpToDate(all) else { continue }
            let result = RegimenAssembler.assemble(text: body, lineParses: parsed, existing: existingForAssembler(who))
            applyText(who, text: body, assembled: result, confirmed: true)
        }
    }
}

/// One medication whose time would move if her text were applied.
struct TextTimeChange: Equatable {
    var id: UUID
    var name: String
    var from: Int
    var to: Int
}

extension AppStore {
    /// What "Update plan" would do to the times of meds she already has, in one routine. Nothing is saved.
    /// New meds are left out (they have no time to move from).
    func previewTimeChanges(_ owner: MedOwner, assembled: RegimenAssembler.Result, routineID: UUID?) -> [TextTimeChange] {
        let current = currentMedications(for: owner)
        var idMap: [UUID: UUID] = [:]
        var pinned: [UUID: DoseTime] = [:]
        for draft in assembled.drafts {
            guard let id = draft.existingID, current.contains(where: { $0.id == id }) else { continue }
            idMap[draft.id] = id
            if let fixed = draft.fixedTime { pinned[id] = fixed }
        }
        let kept = Set(idMap.values)
        guard !kept.isEmpty else { return [] }
        var newRules: [ScheduleRule] = []
        for var rule in assembled.rules {
            rule.subjectID = idMap[rule.subjectID] ?? rule.subjectID
            if let target = rule.targetMedicationID { rule.targetMedicationID = idMap[target] ?? target }
            guard kept.contains(rule.subjectID) else { continue }
            if rule.target == .medication, !kept.contains(rule.targetMedicationID ?? UUID()) { continue }
            rule.owner = owner
            newRules.append(rule)
        }
        let list = templates(for: owner).map { template -> ScheduleTemplate in
            var t = template
            t.doses = t.doses.filter { kept.contains($0.medicationID) }
            for (id, time) in pinned {
                if let i = t.doses.firstIndex(where: { $0.medicationID == id }) {
                    t.doses[i].time = time
                    t.doses[i].pinned = true
                } else {
                    t.doses.append(TemplateDose(medicationID: id, time: time, pinned: true))
                }
            }
            return t
        }
        let generated = ScheduleCycle.generateAll(
            list,
            meds: { self.engineMeds(for: $0).filter { kept.contains($0.id) } },
            rules: { _ in newRules }
        )
        let all = templates(for: owner)
        guard let old = all.first(where: { $0.id == routineID }) ?? all.first,
              let new = generated.templates.first(where: { $0.id == old.id }) else { return [] }
        let names = medicationNames
        var out: [TextTimeChange] = []
        for dose in new.doses {
            guard let before = old.dose(for: dose.medicationID)?.time.minutesFromMidnight else { continue }
            let after = dose.time.minutesFromMidnight
            if before != after {
                out.append(TextTimeChange(id: dose.medicationID, name: names[dose.medicationID] ?? "Medication", from: before, to: after))
            }
        }
        return out.sorted { $0.from < $1.from }
    }
}
