import Foundation

/// One medication as the user listed it in the box, after parsing.
struct RegimenMedDraft: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var friendlyName: String = ""
    /// Only what the user wrote; never filled in by Bloom.
    var dose: String = ""
    /// A clock time the user stated ("at 9 PM").
    var fixedTime: DoseTime?
    /// Set when this matches a medication they already have (keeps its history).
    var existingID: UUID?

    var shortName: String {
        let f = friendlyName.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? name : f
    }
}

extension AppStore {
    // MARK: - Reading

    func templates(for owner: MedOwner) -> [ScheduleTemplate] {
        let order = ScheduleTemplate.orderedDays
        return templates.filter { $0.owner == owner }.sorted { lhs, rhs in
            let a = order.firstIndex { lhs.days.contains($0) } ?? 7
            let b = order.firstIndex { rhs.days.contains($0) } ?? 7
            return (a, lhs.name) < (b, rhs.name)
        }
    }

    func template(for owner: MedOwner, on day: Date) -> ScheduleTemplate? {
        templates(for: owner).first { $0.covers(day) }
    }

    func rules(for owner: MedOwner) -> [ScheduleRule] { rules.filter { $0.owner == owner } }

    func hasRoutine(_ owner: MedOwner) -> Bool { templates.contains { $0.owner == owner } }

    /// Medications placed by templates that are still being taken.
    func scheduledMedications(for owner: MedOwner) -> [Medication] {
        let today = PregnancyMath.calendar.startOfDay(for: now)
        return medications.filter {
            $0.owner == owner && $0.managed && ($0.endDate.map { PregnancyMath.calendar.startOfDay(for: $0) >= today } ?? true)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    var medicationNames: [UUID: String] {
        Dictionary(medications.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
    }

    /// Weekdays (0–6) another template of this person already covers.
    func takenDays(for owner: MedOwner, excluding templateID: UUID?) -> Set<Int> {
        templates(for: owner).filter { $0.id != templateID }.reduce(into: Set<Int>()) { $0.formUnion($1.days) }
    }

    /// The day's meals: a "Just today" set when there is one, otherwise the routine's.
    func meals(for owner: MedOwner, on day: Date) -> [ScheduleMeal] {
        dayRoutine(owner, on: day)?.meals ?? []
    }

    func override(for owner: MedOwner, on day: Date) -> DayOverride? {
        overrides.first { $0.owner == owner && PregnancyMath.calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// The routine a day follows: the one she switched to for that day, otherwise the one for its weekday.
    func activeTemplate(for owner: MedOwner, on day: Date) -> ScheduleTemplate? {
        if let id = override(for: owner, on: day)?.templateID,
           let t = templates.first(where: { $0.id == id && $0.owner == owner }) { return t }
        return template(for: owner, on: day)
    }

    /// Wake, bed and meals for one day, with any "Just today" changes applied.
    func dayRoutine(_ owner: MedOwner, on day: Date) -> (template: ScheduleTemplate, wake: DoseTime, bed: DoseTime, meals: [ScheduleMeal])? {
        guard let t = activeTemplate(for: owner, on: day) else { return nil }
        let o = override(for: owner, on: day)
        return (t, o?.wake ?? t.wake, o?.bed ?? t.bed, (o?.meals ?? t.meals).sorted { $0.time < $1.time })
    }

    func describe(_ rule: ScheduleRule) -> String { ScheduleEngine.describe(rule, names: medicationNames) }

    // MARK: - Engine

    func engineMeds(for template: ScheduleTemplate) -> [EngineMed] {
        scheduledMedications(for: template.owner).map { med in
            let dose = template.dose(for: med.id)
            return EngineMed(id: med.id, name: med.shortName, pinned: dose?.pinned == true ? dose?.time.minutesFromMidnight : nil)
        }
    }

    /// The engine's placement for a template's routine and this person's rules.
    func generate(_ template: ScheduleTemplate) -> (template: ScheduleTemplate, violations: [RuleViolation]) {
        let result = ScheduleEngine.generate(routine: EngineRoutine(template), meds: engineMeds(for: template), rules: rules(for: template.owner))
        var t = template
        t.doses = engineMeds(for: template).compactMap { med in
            guard let minutes = result.times[med.id] else { return nil }
            let existing = template.dose(for: med.id)
            return TemplateDose(id: existing?.id ?? UUID(), medicationID: med.id, time: DoseTime(minutes: minutes), pinned: med.pinned != nil)
        }
        return (t, result.violations)
    }

    /// Broken rules for a template's current (possibly hand-edited) times.
    func violations(in template: ScheduleTemplate) -> [RuleViolation] {
        let times = Dictionary(template.doses.map { ($0.medicationID, $0.time.minutesFromMidnight) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(times.keys)
        let relevant = rules(for: template.owner).filter { ids.contains($0.subjectID) && ($0.target != .medication || ids.contains($0.targetMedicationID ?? UUID())) }
            + ScheduleEngine.dayBounds(for: ids)
        return ScheduleEngine.violations(times: times, routine: EngineRoutine(template), rules: relevant, names: medicationNames)
    }

    // MARK: - Templates

    /// Saves a routine. `regenerate` re-places every medication with the engine (routine or rules changed).
    @discardableResult
    func saveTemplate(_ template: ScheduleTemplate, regenerate: Bool) -> [RuleViolation] {
        var t = template
        if isShared { t.takerID = memberID(for: t.owner) }
        let previousDays = templates.first { $0.id == t.id }?.days ?? t.days
        let autoNamed = t.name.trimmingCharacters(in: .whitespaces).isEmpty
            || t.name == ScheduleTemplate.daysLabel(previousDays) || t.name == ScheduleTemplate.autoName(previousDays)
        // Never let two templates of one person cover the same day.
        t.days.subtract(takenDays(for: t.owner, excluding: t.id))
        // A name made from the days follows the days.
        if autoNamed { t.name = ScheduleTemplate.autoName(t.days) }
        var found: [RuleViolation]
        if regenerate {
            let generated = generate(t)
            t = generated.template
            found = generated.violations
        } else {
            found = violations(in: t)
        }
        t.updatedAt = .now
        if let index = templates.firstIndex(where: { $0.id == t.id }) {
            templates[index] = t
        } else {
            templates.append(t)
        }
        enqueue(.template, t.id.uuidString)
        rebuildPlan()
        saveAndReschedule()
        return found
    }

    func deleteTemplate(_ template: ScheduleTemplate) {
        templates.removeAll { $0.id == template.id }
        overrides.removeAll { $0.templateID == template.id }
        enqueue(.template, template.id.uuidString)
        rebuildPlan()
        saveAndReschedule()
    }

    /// Copies a template's routine and times. The copy gets the days no routine covers (possibly none).
    func duplicateTemplate(_ template: ScheduleTemplate) -> ScheduleTemplate {
        var copy = template
        copy.id = UUID()
        copy.name = ""
        copy.days = Set(0...6).subtracting(takenDays(for: template.owner, excluding: nil))
        copy.meals = template.meals.map { var m = $0; m.id = UUID(); return m }
        copy.doses = template.doses.map { var d = $0; d.id = UUID(); return d }
        saveTemplate(copy, regenerate: false)
        return templates.first { $0.id == copy.id } ?? copy
    }

    // MARK: - The box: medications + rules

    /// Replaces this person's medication list and rules with what the box parsed.
    /// Matching names keep their id and history; medications not listed are stopped from today.
    @discardableResult
    func applyRegimen(owner: MedOwner, meds drafts: [RegimenMedDraft], rules newRules: [ScheduleRule], confirmed: Bool) -> [RuleViolation] {
        var keptIDs = Set<UUID>()
        var pinned: [UUID: DoseTime] = [:]
        // Draft ids → real medication ids (rules reference draft ids).
        var idMap: [UUID: UUID] = [:]
        for draft in drafts {
            if let existingID = draft.existingID, let index = medications.firstIndex(where: { $0.id == existingID }) {
                var med = medications[index]
                med.name = draft.name
                med.friendlyName = draft.friendlyName
                if !draft.dose.trimmingCharacters(in: .whitespaces).isEmpty { med.dose = draft.dose }
                med.managed = true
                med.times = []
                med.endDate = nil
                med.rulesConfirmed = confirmed
                medications[index] = med
                keptIDs.insert(med.id)
                idMap[draft.id] = med.id
            } else {
                var med = Medication(name: draft.name, friendlyName: draft.friendlyName, owner: owner, dose: draft.dose, times: [])
                med.managed = true
                med.rulesConfirmed = confirmed
                if isShared { med.takerID = memberID(for: owner) }
                medications.append(med)
                keptIDs.insert(med.id)
                idMap[draft.id] = med.id
            }
            if let fixed = draft.fixedTime, let id = idMap[draft.id] { pinned[id] = fixed }
        }

        // Stop what wasn't listed.
        let yesterday = PregnancyMath.addDays(-1, to: now)
        for index in medications.indices where medications[index].owner == owner && !keptIDs.contains(medications[index].id) {
            guard medications[index].endDate == nil else { continue }
            medications[index].endDate = max(yesterday, PregnancyMath.calendar.startOfDay(for: medications[index].startDate))
            enqueue(.medication, medications[index].id.uuidString)
        }

        // Rules: replace this person's set.
        for old in rules where old.owner == owner { enqueue(.rule, old.id.uuidString) }
        rules.removeAll { $0.owner == owner }
        for var rule in newRules {
            rule.subjectID = idMap[rule.subjectID] ?? rule.subjectID
            if let target = rule.targetMedicationID { rule.targetMedicationID = idMap[target] ?? target }
            guard keptIDs.contains(rule.subjectID) else { continue }
            if rule.target == .medication, !keptIDs.contains(rule.targetMedicationID ?? UUID()) { continue }
            rule.owner = owner
            rule.takerID = isShared ? memberID(for: owner) : nil
            rule.confirmed = confirmed
            rules.append(rule)
            enqueue(.rule, rule.id.uuidString)
        }

        for id in keptIDs {
            deriveFoodFields(id)
            enqueue(.medication, id.uuidString)
        }

        // Place everything in every routine of this person.
        var found: [RuleViolation] = []
        for template in templates(for: owner) {
            var t = template
            t.doses = t.doses.filter { keptIDs.contains($0.medicationID) }
            for (id, time) in pinned {
                if let i = t.doses.firstIndex(where: { $0.medicationID == id }) {
                    t.doses[i].time = time
                    t.doses[i].pinned = true
                } else {
                    t.doses.append(TemplateDose(medicationID: id, time: time, pinned: true))
                }
            }
            let generated = generate(t)
            if found.isEmpty { found = generated.violations }
            if let index = templates.firstIndex(where: { $0.id == t.id }) {
                templates[index] = generated.template
                templates[index].updatedAt = .now
            }
            enqueue(.template, t.id.uuidString)
        }
        rebuildPlan()
        saveAndReschedule()
        return found
    }

    /// Food windows, the widget and the Live Activity read these fields; they come from the rules.
    private func deriveFoodFields(_ id: UUID) {
        guard let index = medications.firstIndex(where: { $0.id == id }) else { return }
        let mine = rules.filter { $0.subjectID == id }
        var before = 0
        var after = 0
        var withFood = false
        for rule in mine {
            switch (rule.target, rule.relation) {
            case (.food, .before): after = max(after, rule.minMinutes ?? 0)
            case (.food, .after): before = max(before, rule.minMinutes ?? 0)
            case (.food, .apart):
                before = max(before, rule.minMinutes ?? 0)
                after = max(after, rule.minMinutes ?? 0)
            case (.food, .with), (.meal, .with), (.meal, .at): withFood = true
            default: break
            }
        }
        if before > 0 || after > 0 {
            medications[index].foodRule = .emptyStomach
        } else {
            medications[index].foodRule = withFood ? .withFood : .any
        }
        medications[index].noFoodBeforeMinutes = before
        medications[index].noFoodAfterMinutes = after
    }

    /// A deleted medication leaves every routine and rule.
    func removeFromSchedules(_ id: UUID) {
        for index in templates.indices where templates[index].doses.contains(where: { $0.medicationID == id }) {
            templates[index].doses.removeAll { $0.medicationID == id }
            enqueue(.template, templates[index].id.uuidString)
        }
        for rule in rules where rule.involves(id) { enqueue(.rule, rule.id.uuidString) }
        rules.removeAll { $0.involves(id) }
        for index in overrides.indices { overrides[index].times[id] = nil }
    }

    // MARK: - Plan

    /// Writes each scheduled medication's time for today and the next 7 days from its template
    /// (or a \"Just today\" override). Returns true when anything changed.
    @discardableResult
    func rebuildPlan() -> Bool {
        let cal = PregnancyMath.calendar
        let today = cal.startOfDay(for: .now)
        let days = (0...7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let oldest = cal.date(byAdding: .day, value: -60, to: today) ?? today
        var changedOwners = Set<MedOwner>()

        overrides.removeAll { $0.date < cal.date(byAdding: .day, value: -1, to: today) ?? today }

        for index in medications.indices where medications[index].managed {
            let med = medications[index]
            var plan = med.plan.filter { (PlanDay.date($0.key) ?? today) >= oldest }
            for day in days {
                let key = PlanDay.key(day)
                let override = overrides.first { $0.owner == med.owner && cal.isDate($0.date, inSameDayAs: day) }
                let time = override?.times[med.id] ?? (override == nil ? template(for: med.owner, on: day)?.dose(for: med.id)?.time : nil)
                plan[key] = time
            }
            if plan != med.plan {
                medications[index].plan = plan
                changedOwners.insert(med.owner)
            }
        }
        for owner in changedOwners { enqueue(.plan, owner.rawValue) }
        return !changedOwners.isEmpty
    }

    /// First upload after sharing starts.
    func enqueueSchedulesForUpload() {
        for index in templates.indices { templates[index].takerID = memberID(for: templates[index].owner) }
        for index in rules.indices { rules[index].takerID = memberID(for: rules[index].owner) }
        for template in templates { enqueue(.template, template.id.uuidString) }
        for rule in rules { enqueue(.rule, rule.id.uuidString) }
        for owner in Set(medications.filter(\.managed).map(\.owner)) { enqueue(.plan, owner.rawValue) }
    }

    // MARK: - Remote merge

    /// Templates, rules and overrides from a pull. Local versions with unsent changes win.
    func mergeRemoteSchedules(_ remote: RemoteState, medIDs: Set<UUID>) -> (templates: [ScheduleTemplate], rules: [ScheduleRule], overrides: [DayOverride]) {
        func role(_ id: UUID) -> MedOwner { remote.members.first { $0.userID == id }?.role ?? .mom }

        // Templates
        let localTemplates = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newTemplates: [ScheduleTemplate] = []
        var seen = Set<UUID>()
        for row in remote.templates {
            seen.insert(row.id)
            if hasPendingOp(.template, row.id.uuidString) {
                if let local = localTemplates[row.id] { newTemplates.append(local) }
                continue
            }
            let items = remote.templateItems.filter { $0.template_id == row.id }
            var t = ScheduleTemplate(
                id: row.id, owner: role(row.taker_id), takerID: row.taker_id, name: row.name,
                days: Set((row.days_of_week ?? Array(0...6)).filter { (0...6).contains($0) }),
                wake: SyncFormat.time(from: row.wake_time), bed: SyncFormat.time(from: row.bed_time)
            )
            let mealItems = items.filter { $0.kind == "meal" }
            if !mealItems.isEmpty {
                t.meals = mealItems.sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }.map {
                    ScheduleMeal(id: $0.id, name: $0.label ?? "Meal", time: SyncFormat.time(from: $0.time_of_day), durationMinutes: $0.duration_min ?? 30)
                }
            } else {
                t.meals = (row.meals ?? []).map {
                    ScheduleMeal(id: $0.id.flatMap(UUID.init(uuidString:)) ?? UUID(), name: $0.name, time: SyncFormat.time(from: $0.time), durationMinutes: $0.duration_min ?? 30)
                }
            }
            t.doses = items.filter { $0.kind == "medication" }.compactMap { item in
                guard let medID = item.medication_id, medIDs.contains(medID) else { return nil }
                return TemplateDose(id: item.id, medicationID: medID, time: SyncFormat.time(from: item.time_of_day), pinned: item.pinned ?? false)
            }
            t.updatedAt = row.updated_at ?? localTemplates[row.id]?.updatedAt ?? .now
            newTemplates.append(t)
        }
        for local in templates where !seen.contains(local.id) && hasPendingOp(.template, local.id.uuidString) {
            newTemplates.append(local)
        }

        // Rules
        let localRules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newRules: [ScheduleRule] = []
        var seenRules = Set<UUID>()
        for row in remote.rules where medIDs.contains(row.subject_medication_id) {
            seenRules.insert(row.id)
            if hasPendingOp(.rule, row.id.uuidString) {
                if let local = localRules[row.id] { newRules.append(local) }
                continue
            }
            guard let relation = RuleRelation(rawValue: row.relation), let target = RuleTarget(rawValue: row.target_type) else { continue }
            newRules.append(ScheduleRule(
                id: row.id, owner: role(row.taker_id), takerID: row.taker_id, subjectID: row.subject_medication_id,
                relation: relation, target: target, targetMedicationID: row.target_medication_id, targetMeal: row.target_meal,
                minMinutes: row.min_minutes, maxMinutes: row.max_minutes, sourceText: row.source_text ?? "", confirmed: row.confirmed ?? false
            ))
        }
        for local in rules where !seenRules.contains(local.id) && hasPendingOp(.rule, local.id.uuidString) {
            newRules.append(local)
        }

        // Overrides: one per person per day.
        var newOverrides: [DayOverride] = []
        for owner in MedOwner.allCases {
            if hasPendingOp(.plan, owner.rawValue) {
                newOverrides += overrides.filter { $0.owner == owner }
                continue
            }
            let rows = remote.overrideDoses.filter { role($0.taker_id) == owner && medIDs.contains($0.medication_id) }
            for (dateKey, dayRows) in Dictionary(grouping: rows, by: \.local_date) {
                guard let date = PlanDay.date(String(dateKey.prefix(10))) else { continue }
                var times: [UUID: DoseTime] = [:]
                for row in dayRows { times[row.medication_id] = DoseTime(date: row.scheduled_for) }
                let existing = overrides.first { $0.owner == owner && PregnancyMath.calendar.isDate($0.date, inSameDayAs: date) }
                // Day-only meals, wake and bed live on this device; keep them across pulls.
                newOverrides.append(DayOverride(id: existing?.id ?? UUID(), owner: owner, takerID: dayRows.first?.taker_id,
                                                date: date, times: times, templateID: dayRows.first?.template_id,
                                                meals: existing?.meals, wake: existing?.wake, bed: existing?.bed))
            }
        }
        newOverrides.sort { ($0.date, $0.owner.rawValue) < ($1.date, $1.owner.rawValue) }
        let currentOverrides = overrides.sorted { ($0.date, $0.owner.rawValue) < ($1.date, $1.owner.rawValue) }
        // Keep local ids/order stable so an unchanged pull doesn't look like a change.
        let overridesOut = newOverrides.map { $0.times }.elementsEqual(currentOverrides.map { $0.times }) && newOverrides.count == currentOverrides.count
            ? overrides : newOverrides

        return (newTemplates.sorted { $0.id.uuidString < $1.id.uuidString } == templates.sorted { $0.id.uuidString < $1.id.uuidString } ? templates : newTemplates,
                newRules.sorted { $0.id.uuidString < $1.id.uuidString } == rules.sorted { $0.id.uuidString < $1.id.uuidString } ? rules : newRules,
                overridesOut)
    }
}
