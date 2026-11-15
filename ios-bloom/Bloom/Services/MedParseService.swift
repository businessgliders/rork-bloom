import Foundation

/// Parts of a parsed medication that can be marked "Suggested" (not stated in the user's text).
enum MedField: String, Hashable, CaseIterable {
    case schedule, time, food, minutes
}

/// One short follow-up question when the text leaves something unclear (usually the time).
struct MedFollowUp: Equatable {
    struct Option: Equatable, Hashable, Identifiable {
        var label: String
        var times: [DoseTime]
        var id: String { label }
    }
    var question: String
    var options: [Option]
}

/// What the AI read from a typed sentence or filtered label text.
/// Dose and strength only ever come from the text itself; they are blank otherwise.
struct MedParseResult: Equatable {
    var fullName: String
    var friendlyName: String
    var emoji: String
    var dose: String
    var schedule: MedSchedule
    var times: [DoseTime]
    var foodRule: FoodRule
    var noFoodBeforeMinutes: Int
    var noFoodAfterMinutes: Int
    var suggested: Set<MedField>
    var followUp: MedFollowUp?
}

/// Turns one natural-language line (or label text) into a medication draft through the Rork AI proxy
/// (Rork → Vercel AI Gateway → Google Gemini). Only the text is sent, never a photo.
enum MedParseService {
    private static let systemPrompt = """
    You help a pregnant person set up reminders for a medication or supplement their clinician already prescribed. \
    You receive ONE short text: either a sentence they typed or text read from a medication box/label. \
    Return a JSON object with exactly these keys:
    {"fullName": string (product or generic name as written, no strength), \
    "friendlyName": string (1-2 everyday words, e.g. "Iron", "Thyroid", "Prenatal"), \
    "emoji": one of "💊","🌿","🍊","🫐","💧","🌸","☀️","🌙","🩷","🧡", \
    "amount": string (how many units per dose, e.g. "1 tablet", ONLY if written in the text, else ""), \
    "strength": string (e.g. "325 mg", ONLY if written in the text, else ""), \
    "schedule": {"type": "daily" | "weekdays", "days": [1-7, 1 = Sunday]}, "scheduleStated": boolean, \
    "times": ["HH:mm" 24h], "timeStated": boolean (true ONLY if an exact clock time is written for every dose), \
    "foodRule": "empty_stomach" | "with_food" | "any", "foodStated": boolean, \
    "noFoodBeforeMinutes": integer 0-240, "noFoodAfterMinutes": integer 0-240, "minutesStated": boolean, \
    "followUp": null or {"question": string max 60 chars, "options": [{"label": string max 24 chars, "times": ["HH:mm"]}] (2-4 options)}}
    Rules: \
    - NEVER invent, suggest or complete an amount, dose or strength. If it is not literally in the text, use "". \
    - Never give advice about whether to take, stop or change a medication, and no pregnancy safety judgements. \
    - If timeStated is false, give a followUp asking when they take it, with clock-time options that fit what was said \
      (e.g. "in the morning" → 7:00, 8:00, 9:00; "twice a day" → "8 AM & 8 PM" with two times). Still fill "times" with your best guess. \
    - If the food rule or no-food minutes are not stated, fill in GENERAL label-level guidance for this product and mark them not stated. \
      Use 0 minutes unless the product is commonly taken on an empty stomach. \
    - "every day", "daily" or no frequency = daily. \
    Reply with JSON only.
    """

    static func parse(text: String) async throws -> MedParseResult {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        guard !base.isEmpty, !secret.isEmpty, let url = URL(string: "\(base)/v2/vercel/v1/chat/completions") else {
            throw MedLookupService.LookupError.notConfigured
        }
        let input = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))

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
        request.timeoutInterval = 45

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

    /// Defensive decoding: clamps every value, drops any dose that isn't in the source text,
    /// and always asks about the time when none was written.
    static func decode(_ text: String, source: String) throws -> MedParseResult {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MedLookupService.LookupError.unreadable
        }

        func string(_ key: String, max: Int) -> String {
            String((json[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        }
        func bool(_ key: String) -> Bool { json[key] as? Bool ?? false }
        func minutes(_ key: String) -> Int {
            let value = (json[key] as? NSNumber)?.intValue ?? Int(json[key] as? String ?? "") ?? 0
            return min(max(value, 0), 240)
        }

        let fullName = string("fullName", max: 60)
        guard !fullName.isEmpty else { throw MedLookupService.LookupError.unreadable }
        var friendly = string("friendlyName", max: 24)
        if friendly.caseInsensitiveCompare(fullName) == .orderedSame { friendly = "" }

        let emojiValue = string("emoji", max: 4)
        let emoji = Medication.emojiChoices.contains(emojiValue) ? emojiValue : "💊"

        // Dose: only what's literally in the text.
        let amount = verifiedDosePart(string("amount", max: 30), in: source)
        let strength = verifiedDosePart(string("strength", max: 30), in: source)
        let dose = [amount, strength].filter { !$0.isEmpty }.joined(separator: ", ")

        // Schedule
        var schedule = MedSchedule.daily
        if let s = json["schedule"] as? [String: Any], (s["type"] as? String) == "weekdays" {
            let days = Set((s["days"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { (1...7).contains($0) })
            if !days.isEmpty && days.count < 7 { schedule = .weekdays(days) }
        }

        // Times
        let times = parseTimes(json["times"])
        let timeStated = bool("timeStated") && !times.isEmpty

        // Food
        let rule = FoodRule(rawValue: string("foodRule", max: 20).lowercased()) ?? .any
        var before = minutes("noFoodBeforeMinutes")
        var after = minutes("noFoodAfterMinutes")
        if rule != .emptyStomach { before = 0; after = 0 }

        var suggested = Set<MedField>()
        if !bool("scheduleStated") { suggested.insert(.schedule) }
        if !timeStated { suggested.insert(.time) }
        if !bool("foodStated") { suggested.insert(.food) }
        if rule == .emptyStomach && !bool("minutesStated") { suggested.insert(.minutes) }

        // Follow-up when no clock time was given.
        var followUp: MedFollowUp?
        if !timeStated {
            var options: [MedFollowUp.Option] = []
            if let f = json["followUp"] as? [String: Any] {
                for raw in (f["options"] as? [[String: Any]] ?? []).prefix(4) {
                    let label = String((raw["label"] as? String ?? "").prefix(24))
                    let optionTimes = parseTimes(raw["times"])
                    if !label.isEmpty, !optionTimes.isEmpty, !options.contains(where: { $0.label == label }) {
                        options.append(.init(label: label, times: optionTimes))
                    }
                }
                let question = String((f["question"] as? String ?? "").prefix(60))
                if options.count >= 2 {
                    followUp = MedFollowUp(question: question.isEmpty ? "What time do you take it?" : question, options: options)
                }
            }
            if followUp == nil { followUp = defaultFollowUp(count: max(times.count, 1)) }
        }

        return MedParseResult(
            fullName: fullName,
            friendlyName: friendly,
            emoji: emoji,
            dose: dose,
            schedule: schedule,
            times: times.isEmpty ? [DaySlot.morning.defaultTime] : times,
            foodRule: rule,
            noFoodBeforeMinutes: before,
            noFoodAfterMinutes: after,
            suggested: suggested,
            followUp: followUp
        )
    }

    static func defaultFollowUp(count: Int) -> MedFollowUp {
        if count >= 2 {
            return MedFollowUp(question: "When do you take them?", options: [
                .init(label: "8 AM & 8 PM", times: [DoseTime(hour: 8, minute: 0), DoseTime(hour: 20, minute: 0)]),
                .init(label: "7 AM & 7 PM", times: [DoseTime(hour: 7, minute: 0), DoseTime(hour: 19, minute: 0)]),
                .init(label: "9 AM & 9 PM", times: [DoseTime(hour: 9, minute: 0), DoseTime(hour: 21, minute: 0)]),
            ])
        }
        return MedFollowUp(question: "What time do you take it?", options: [
            .init(label: "7:00 AM", times: [DoseTime(hour: 7, minute: 0)]),
            .init(label: "8:00 AM", times: [DoseTime(hour: 8, minute: 0)]),
            .init(label: "1:00 PM", times: [DoseTime(hour: 13, minute: 0)]),
            .init(label: "9:00 PM", times: [DoseTime(hour: 21, minute: 0)]),
        ])
    }

    private static func parseTimes(_ value: Any?) -> [DoseTime] {
        let strings = (value as? [Any] ?? []).compactMap { $0 as? String }
        var result: [DoseTime] = []
        for s in strings.prefix(6) {
            let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { continue }
            let time = DoseTime(hour: parts[0], minute: parts[1])
            if !result.contains(time) { result.append(time) }
        }
        return result.sorted()
    }

    /// Keeps a dose part only when its numbers (or, with no numbers, its words) appear in the source text.
    static func verifiedDosePart(_ part: String, in source: String) -> String {
        guard !part.isEmpty else { return "" }
        var haystack = source.lowercased()
        // "one tablet" in the text supports "1 tablet".
        let words = ["one": "1", "two": "2", "three": "3", "four": "4", "half": "0.5", "a tablet": "1 tablet", "a capsule": "1 capsule", "a pill": "1 pill"]
        for (word, digit) in words where haystack.contains(word) { haystack += " \(digit)" }
        let numbers = part.lowercased().split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "," })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
            .filter { !$0.isEmpty }
        if !numbers.isEmpty {
            return numbers.allSatisfy({ haystack.contains($0) }) ? part : ""
        }
        let partWords = part.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        return !partWords.isEmpty && partWords.allSatisfy({ haystack.contains($0) }) ? part : ""
    }
}
