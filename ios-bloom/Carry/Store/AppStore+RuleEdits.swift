import Foundation

/// Rules compared by meaning (ids of the rules themselves don't matter).
nonisolated enum RuleSignature {
    static func key(_ r: ScheduleRule) -> String {
        [r.subjectID.uuidString, r.relation.rawValue, r.target.rawValue, r.targetMedicationID?.uuidString ?? "",
         (r.targetMeal ?? "").lowercased(), r.minMinutes.map(String.init) ?? "", r.maxMinutes.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    static func same(_ a: [ScheduleRule], _ b: [ScheduleRule]) -> Bool {
        a.map(key).sorted() == b.map(key).sorted()
    }

    static func contains(_ list: [ScheduleRule], _ rule: ScheduleRule) -> Bool {
        let k = key(rule)
        return list.contains { key($0) == k }
    }

    /// "X apart from Y" and "Y apart from X" with the same gap: one instruction written both ways.
    static func mirrors(_ a: ScheduleRule, _ b: ScheduleRule) -> Bool {
        ScheduleEngine.mirrors(a, b)
    }

    /// Same rule, or the same gap rule written the other way round.
    static func matches(_ a: ScheduleRule, _ b: ScheduleRule) -> Bool {
        key(a) == key(b) || mirrors(a, b)
    }
}

/// What she can tap on a rule row: the value, its step, and the words around it.
nonisolated enum RuleValues {
    enum Control: Equatable {
        /// One stepper over `minMinutes`.
        case minutes(step: Int, lowest: Int)
        /// From/to steppers ("10 h–12 h apart").
        case range(step: Int)
        /// A meal picker.
        case meal
        /// Nothing to change ("together with Iron").
        case none
    }

    static func control(for rule: ScheduleRule) -> Control {
        switch (rule.target, rule.relation) {
        case (.medication, .with): return .none
        case (.food, .with): return .none
        case (.meal, .with), (.meal, .at) where (rule.minMinutes ?? 0) == 0 && rule.maxMinutes == nil: return .meal
        case (.food, _): return .minutes(step: 15, lowest: 15)
        case (.wake, .at) where (rule.minMinutes ?? 0) == 0 && rule.maxMinutes == nil: return .none
        case (.bed, .at) where (rule.minMinutes ?? 0) == 0 && rule.maxMinutes == nil: return .none
        case (.wake, _), (.bed, _):
            return rule.maxMinutes != nil && rule.minMinutes != nil ? .range(step: 15) : .minutes(step: 15, lowest: 0)
        case (.medication, _), (.meal, _):
            if rule.maxMinutes != nil, rule.minMinutes != nil, (rule.maxMinutes ?? 0) > (rule.minMinutes ?? 0) {
                return .range(step: step(for: rule.minMinutes ?? 0))
            }
            return .minutes(step: step(for: rule.minMinutes ?? 0), lowest: rule.target == .medication && rule.relation == .apart ? 60 : 15)
        }
    }

    /// Medication gaps move by the hour once they're an hour or more; everything shorter by 15 minutes.
    static func step(for minutes: Int) -> Int { minutes >= 60 ? 60 : 15 }

    /// One step up or down, never below `lowest`, never past 23 h.
    static func stepped(_ value: Int, up: Bool, lowest: Int) -> Int {
        let s = up ? step(for: value) : step(for: value - 1)
        let next = up ? value + s : value - s
        return min(max(next, lowest), 23 * 60)
    }

    /// "No food after · 30 min", "At least 4 h after Thyroid", "With lunch", "10 h–12 h apart from Progesterone PM".
    static func title(_ rule: ScheduleRule, names: [UUID: String]) -> String {
        let minV = rule.minMinutes ?? 0
        let target = rule.targetMedicationID.flatMap { names[$0] } ?? "another medication"
        switch (rule.target, rule.relation) {
        case (.food, .before): return "No food after · \(ScheduleEngine.duration(minV))"
        case (.food, .after): return "No food before · \(ScheduleEngine.duration(minV))"
        case (.food, .apart): return "No food before or after · \(ScheduleEngine.duration(minV))"
        case (.meal, .with): return "With \((rule.targetMeal ?? "a meal").lowercased())"
        case (.medication, .after) where rule.maxMinutes == nil && minV > 0:
            return "At least \(ScheduleEngine.duration(minV)) after \(target)"
        case (.medication, .before) where rule.maxMinutes == nil && minV > 0:
            return "At least \(ScheduleEngine.duration(minV)) before \(target)"
        default:
            let text = ScheduleEngine.describe(rule, names: names, includeSubject: false)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }
}

extension AppStore {
    /// The rules the plan screen shows for this person: a pending rule edit's, else the saved ones.
    func shownRules(_ owner: MedOwner) -> [ScheduleRule] {
        if let change = scheduleChange, change.kind == .rule, change.owner == owner, let draft = change.draftRules { return draft }
        return rules(for: owner)
    }

    /// Saves this person's whole rule set, confirmed against her doctor or pharmacist.
    func commitRules(_ owner: MedOwner, _ newRules: [ScheduleRule]) {
        for old in rules where old.owner == owner { enqueue(.rule, old.id.uuidString) }
        rules.removeAll { $0.owner == owner }
        for var rule in newRules {
            rule.owner = owner
            rule.takerID = isShared ? memberID(for: owner) : nil
            rule.confirmed = true
            rules.append(rule)
            enqueue(.rule, rule.id.uuidString)
        }
        for med in currentMedications(for: owner) {
            deriveFoodFields(med.id)
            if let i = medications.firstIndex(where: { $0.id == med.id }) { medications[i].rulesConfirmed = true }
            enqueue(.medication, med.id.uuidString)
        }
        medsText[owner] = planText(owner)
    }

    /// New medications from "Add a medication", with their rules (already confirmed in the sheet).
    /// Returns the first new medication's id.
    @discardableResult
    func addMedications(_ owner: MedOwner, drafts: [RegimenMedDraft], rules newRules: [ScheduleRule]) -> UUID? {
        var idMap: [UUID: UUID] = [:]
        var pinned: [UUID: DoseTime] = [:]
        var nextOrder = (currentMedications(for: owner).compactMap(\.textOrder).max() ?? -1) + 1
        var firstNew: UUID?
        for draft in drafts {
            if let existing = draft.existingID { idMap[draft.id] = existing; continue }
            var med = Medication(name: draft.name, friendlyName: draft.friendlyName, owner: owner, dose: draft.dose, times: [])
            med.managed = true
            med.rulesConfirmed = true
            med.textOrder = nextOrder
            nextOrder += 1
            if isShared { med.takerID = memberID(for: owner) }
            medications.append(med)
            enqueue(.medication, med.id.uuidString)
            idMap[draft.id] = med.id
            if firstNew == nil { firstNew = med.id }
            if let fixed = draft.fixedTime { pinned[med.id] = fixed }
        }
        let known = Set(currentMedications(for: owner).map(\.id))
        var all = rules(for: owner)
        for var rule in newRules {
            rule.subjectID = idMap[rule.subjectID] ?? rule.subjectID
            if let t = rule.targetMedicationID { rule.targetMedicationID = idMap[t] ?? t }
            guard known.contains(rule.subjectID) else { continue }
            if rule.target == .medication, !known.contains(rule.targetMedicationID ?? UUID()) { continue }
            if RuleSignature.contains(all, rule) { continue }
            all.append(rule)
        }
        commitRules(owner, all)
        let prepared = templates(for: owner).map { template -> ScheduleTemplate in
            var t = template
            for (id, time) in pinned { t.doses.append(TemplateDose(medicationID: id, time: time, pinned: true)) }
            return t
        }
        let generated = generateCycle(owner, replacing: prepared)
        storeGenerated(generated.templates)
        medsText[owner] = planText(owner)
        rebuildPlan()
        saveAndReschedule()
        return firstNew
    }

    /// Drag to reorder on the plan screen: her order is also the same-time order everywhere.
    func reorderMedications(_ owner: MedOwner, ids: [UUID]) {
        var changed = false
        for (index, id) in ids.enumerated() {
            guard let i = medications.firstIndex(where: { $0.id == id }), medications[i].textOrder != index else { continue }
            medications[i].textOrder = index
            enqueue(.medication, id.uuidString)
            changed = true
        }
        guard changed else { return }
        storeGenerated(generateCycle(owner).templates)
        medsText[owner] = planText(owner)
        rebuildPlan()
        saveAndReschedule()
    }

    /// The plan written out as text, so "Start over from text" begins from what she has now:
    /// "Name dose", then one "Name <rule>" line per rule, a blank line between medications.
    func planText(_ owner: MedOwner) -> String {
        let meds = currentMedications(for: owner).filter(\.managed)
        let names = Dictionary(currentMedications(for: owner).map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
        let ownerRules = rules(for: owner)
        var blocks: [String] = []
        for med in meds {
            var lines = [med.dose.isEmpty ? med.shortName : "\(med.shortName) \(med.dose)"]
            if let days = med.schedule.daysNote { lines.append("\(med.shortName) every \(days)") }
            if let pin = templates(for: owner).lazy.compactMap({ $0.dose(for: med.id) }).first(where: \.pinned) {
                lines.append("\(med.shortName) at \(ScheduleEngine.clock(pin.time.minutesFromMidnight))")
            }
            for rule in ownerRules where rule.subjectID == med.id {
                lines.append("\(med.shortName) \(ScheduleEngine.describe(rule, names: names, includeSubject: false))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}
