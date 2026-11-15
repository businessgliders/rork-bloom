import Foundation

/// A question asked only when a rule in the user's text is truly ambiguous or contradictory.
/// Picking an option adds its clarification to the text and parses again.
struct RegimenQuestion: Equatable, Identifiable {
    struct Option: Equatable, Hashable, Identifiable {
        var label: String
        var clarification: String
        var id: String { label }
    }
    var question: String
    var options: [Option]
    var id: String { question }
}

/// What the AI read from the one box: the medication list and the timing rules, nothing calculated.
struct RegimenParseResult: Equatable {
    var meds: [RegimenMedDraft]
    /// Rules reference `RegimenMedDraft.id`.
    var rules: [ScheduleRule]
    var questions: [RegimenQuestion]
}

/// Turns the user's own description of all their medications into a list + rules through the Rork AI proxy.
/// The AI only parses; times are placed by `ScheduleEngine`.
enum RegimenParseService {
    private static let systemPrompt = """
    You read a pregnant person's own description of the medications and supplements their clinician already prescribed, \
    and turn it into a list plus timing rules. You NEVER calculate or suggest clock times; app code does that. \
    Return a JSON object with exactly these keys:
    {"meds": [{"key": short unique id like "m1", "name": product or generic name as written (no strength), \
    "friendlyName": 1-2 everyday words ("Thyroid", "Iron", "Prenatal"), \
    "amount": units per dose ONLY if literally written (e.g. "1 tablet") else "", \
    "strength": e.g. "325 mg" ONLY if literally written else "", \
    "fixedTime": "HH:mm" 24h ONLY if the text gives an exact clock time for it, else null}], \
    "rules": [{"subject": med key, \
    "relation": "before"|"after"|"apart"|"with"|"at", \
    "targetType": "medication"|"food"|"meal"|"wake"|"bed", \
    "target": med key when targetType is "medication"; meal name ("breakfast","lunch","dinner","snack") when "meal"; else null, \
    "min": integer minutes or null, "max": integer minutes or null, \
    "sourceText": the short phrase it came from}], \
    "questions": [{"question": string max 80 chars, "options": [{"label": max 30 chars, "clarification": a sentence restating the rule unambiguously}]}]}
    How to encode:
    - "as soon as I wake up" / "first thing" → at wake, min 0. "30 min after waking" → after wake, min 30.
    - "no food for 30 min after" / "on an empty stomach, wait 30 min to eat" → before food, min 30.
    - "no food 1 hour before" → after food, min 60. "no food 1 hour before or after" → apart food, min 60.
    - "with lunch" → with meal "lunch". "with food" / "with a meal" → with food.
    - "X 4 hours after Y" → subject X, after medication Y, min 240. "keep X and Y 2 hours apart" → subject X, apart medication Y, min 120.
    - "before bed" → before bed, min 0. "at bedtime" → at bed, min 0.
    Rules:
    - Only rules the person actually wrote. Never add general guidance, never invent interactions.
    - NEVER invent an amount or strength. No advice about taking, stopping or changing anything; no pregnancy safety judgements.
    - A medication mentioned only as a rule target is still in "meds".
    - Ask a question ONLY when a rule is truly ambiguous or two rules contradict each other. Never ask about wake time, \
      meals, bedtime or when to take something; the person's routine answers those. Usually "questions" is [].
    Reply with JSON only.
    """

    static func parse(text: String) async throws -> RegimenParseResult {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        guard !base.isEmpty, !secret.isEmpty, let url = URL(string: "\(base)/v2/vercel/v1/chat/completions") else {
            throw MedLookupService.LookupError.notConfigured
        }
        let input = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        let body: [String: Any] = [
            "model": MedLookupService.model,
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Text: \(input)"],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, _) = try await sendWithRetry(request)
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              !content.isEmpty else { throw ProxyError.noData }
        return try decode(content, source: input)
    }

    /// Defensive decoding: drops rules that point at unknown medications or make no sense,
    /// clamps minutes, and keeps doses only when they're in the source text.
    static func decode(_ text: String, source: String) throws -> RegimenParseResult {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MedLookupService.LookupError.unreadable
        }
        func str(_ dict: [String: Any], _ key: String, max: Int) -> String {
            String((dict[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        }
        func minutes(_ value: Any?) -> Int? {
            guard let v = (value as? NSNumber)?.intValue ?? (value as? String).flatMap({ Int($0) }) else { return nil }
            return min(max(v, 0), 24 * 60)
        }

        var meds: [RegimenMedDraft] = []
        var keys: [String: UUID] = [:]
        for raw in (json["meds"] as? [[String: Any]] ?? []).prefix(20) {
            let rawName = str(raw, "name", max: 60)
            // "calcium" → "Calcium"; leave the rest as written ("L-thyroxine", "D3").
            let name = rawName.prefix(1).uppercased() + rawName.dropFirst()
            guard !name.isEmpty else { continue }
            var friendly = str(raw, "friendlyName", max: 24)
            if friendly.caseInsensitiveCompare(name) == .orderedSame { friendly = "" }
            // Same medicine named twice: keep one.
            if let existing = meds.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                keys[str(raw, "key", max: 20)] = existing.id
                continue
            }
            let amount = MedParseService.verifiedDosePart(str(raw, "amount", max: 30), in: source)
            let strength = MedParseService.verifiedDosePart(str(raw, "strength", max: 30), in: source)
            var draft = RegimenMedDraft(name: name, friendlyName: friendly,
                                        dose: [amount, strength].filter { !$0.isEmpty }.joined(separator: ", "))
            if let fixed = raw["fixedTime"] as? String {
                let parts = fixed.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) {
                    draft.fixedTime = DoseTime(hour: parts[0], minute: parts[1])
                }
            }
            let key = str(raw, "key", max: 20)
            keys[key.isEmpty ? name : key] = draft.id
            keys[name.lowercased()] = draft.id
            if !friendly.isEmpty { keys[friendly.lowercased()] = draft.id }
            meds.append(draft)
        }
        guard !meds.isEmpty else { throw MedLookupService.LookupError.unreadable }
        func med(_ key: Any?) -> UUID? {
            guard let k = (key as? String)?.trimmingCharacters(in: .whitespaces), !k.isEmpty else { return nil }
            return keys[k] ?? keys[k.lowercased()]
        }

        var rules: [ScheduleRule] = []
        for raw in (json["rules"] as? [[String: Any]] ?? []).prefix(40) {
            guard let subject = med(raw["subject"]),
                  let relation = RuleRelation(rawValue: str(raw, "relation", max: 12).lowercased()),
                  let target = RuleTarget(rawValue: str(raw, "targetType", max: 12).lowercased()) else { continue }
            var rule = ScheduleRule(subjectID: subject, relation: relation, target: target,
                                    minMinutes: minutes(raw["min"]), maxMinutes: minutes(raw["max"]),
                                    sourceText: str(raw, "sourceText", max: 120))
            switch target {
            case .medication:
                guard let other = med(raw["target"]), other != subject else { continue }
                rule.targetMedicationID = other
            case .meal:
                let meal = str(raw, "target", max: 24)
                guard !meal.isEmpty else { continue }
                rule.targetMeal = meal.capitalized
            case .food, .wake, .bed:
                break
            }
            // "with" only makes sense for meals and food.
            if relation == .with, target != .meal, target != .food { continue }
            if let lo = rule.minMinutes, let hi = rule.maxMinutes, hi < lo { rule.maxMinutes = nil }
            if relation == .apart, (rule.minMinutes ?? 0) == 0 { continue }
            // Drop exact duplicates.
            if rules.contains(where: { $0.subjectID == rule.subjectID && $0.relation == rule.relation && $0.target == rule.target
                && $0.targetMedicationID == rule.targetMedicationID && $0.targetMeal == rule.targetMeal && $0.minMinutes == rule.minMinutes }) { continue }
            rules.append(rule)
        }

        var questions: [RegimenQuestion] = []
        for raw in (json["questions"] as? [[String: Any]] ?? []).prefix(2) {
            let q = str(raw, "question", max: 80)
            let options: [RegimenQuestion.Option] = (raw["options"] as? [[String: Any]] ?? []).prefix(4).compactMap {
                let label = str($0, "label", max: 30)
                let clar = str($0, "clarification", max: 200)
                return label.isEmpty || clar.isEmpty ? nil : .init(label: label, clarification: clar)
            }
            if !q.isEmpty, options.count >= 2 { questions.append(RegimenQuestion(question: q, options: options)) }
        }
        return RegimenParseResult(meds: meds, rules: rules, questions: questions)
    }
}
