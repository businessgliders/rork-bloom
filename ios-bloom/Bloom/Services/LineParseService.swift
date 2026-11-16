import Foundation
import Observation

// MARK: - What one line says

/// What the AI read from one line of "Your meds & rules". Names only; ids are matched later by `RegimenAssembler`.
nonisolated struct LineParse: Codable, Equatable, Sendable {
    struct Med: Codable, Equatable, Sendable {
        var name: String
        var dose: String = ""
        var time: DoseTime?
    }
    struct Rule: Codable, Equatable, Sendable {
        var subject: String
        var relation: String
        var targetType: String
        var target: String?
        var min: Int?
        var max: Int?
    }
    var meds: [Med] = []
    var rules: [Rule] = []
    /// The line has a rule but doesn't say which medication it is about ("30 minutes afterwards no food").
    /// Such a line is read again with the line above it as context.
    var needsContext: Bool = false

    /// A line that says which medication it is about, so the lines under it can borrow it.
    var namesSubject: Bool { !needsContext && !meds.isEmpty }
}

// MARK: - Prompt, models, decoding

nonisolated enum LineParseError: Error, Equatable {
    case notConfigured
    case unreadable
}

/// Parses one line at a time through the Rork AI proxy. The AI only reads; `ScheduleEngine` places times.
/// Prompt mirrors `scripts/line_parse_prompt.txt`, which `scripts/bench_line_parse.py` benchmarks.
nonisolated enum LineParseService {
    /// Fastest model that passed the line tests (median 1.9 s for five lines in parallel, 2026-11-15).
    static let model = "deepseek/deepseek-v4.1-flash-1017-ultrafast"
    /// Used for the single retry.
    static let fallbackModel = "anthropic/claude-haiku-5.5"
    /// The fast model answers in under a second; when it's down, give up quickly and ask the fallback.
    static let timeout: TimeInterval = 6
    static let fallbackTimeout: TimeInterval = 15
    static let maxTokens = 400

    static let systemPrompt = """
    Parse one line a pregnant person wrote about medications her clinician prescribed. Only parse; never suggest times, doses or advice.
    Return JSON: {"meds":[{"name":str,"dose":str,"time":"HH:mm"|null}],"rules":[{"subject":str,"relation":"before"|"after"|"apart"|"with"|"at","targetType":"medication"|"food"|"meal"|"wake"|"bed","target":str|null,"min":int|null,"max":int|null}],"needsContext":bool}
    - meds: every medication named in the line. Use the exact Known name when it matches (case-insensitive); else the name as written, without "the"/"my". dose only if literally written, else "". time only for an exact clock time written.
    - subject/target: med names from meds. target is a meal name ("breakfast","lunch","dinner","snack") for meal, else null.
    - Minutes: "as soon as I wake" = at wake 0. "30 min after waking" = after wake 30. "no food for 30 min after" = before food 30. "no food 1 h before" = after food 60. "no food 1 h before or after" = apart food 60. "with lunch" = with meal lunch. "with food" = with food. "X 4 h after Y" = X after medication Y 240. "X and Y 2 h apart" = X apart medication Y 120. "X with Y" (Y a medication) = X with medication Y 0. "before bed" = before bed 0. "at bedtime" = at bed 0. "first thing in the morning" = at wake 0. "30 minutes afterwards I can't have any food" = before food 30. "cannot have food 2 hours before" = after food 120. "or 1 hour afterwards" (food) = before food 60. "within 1 hour after dinner" = after meal dinner min 0 max 60. "approximately 10 to 12 hours apart from Y" = apart medication Y min 600 max 720. "at least 4 hours after taking Y" = after medication Y 240.
    - Only rules actually written. Empty arrays if none.
    - If Line has a rule but doesn't say which medication it is about ("30 min afterwards no food", "or 1 hour after", "apart from X" with no other medication), use the medication from Context as subject and include it in meds (Context "Iron", Line "at least 4 hours after taking the thyroid" = Iron after medication Thyroid 240). Without Context, leave those rules out and set "needsContext":true. Never parse Context's own rules.
    """

    /// The text sent for a line: "@" tokens lose their marker, bullets and extra spaces go.
    static func normalize(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "@", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "• ", "* ", "– "] where s.hasPrefix(bullet) { s = String(s.dropFirst(bullet.count)) }
        if let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let head = s[s.startIndex..<dot]
            if (1...2).contains(head.count), head.allSatisfy(\.isNumber) {
                s = String(s[s.index(after: dot)...])
            }
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func userMessage(line: String, context: [String] = [], known: [String]) -> String {
        var out = "Known: \(known.isEmpty ? "none" : known.joined(separator: ", "))\n"
        if !context.isEmpty {
            out += "Context (lines just above, only to tell which medication Line is about):\n"
            out += context.map { String($0.prefix(300)) }.joined(separator: "\n") + "\n"
        }
        return out + "Line: \(String(line.prefix(400)))"
    }

    /// Cache key for a line read with context: changes whenever the context lines change.
    static func contextKey(_ line: String, context: [String]) -> String {
        context.isEmpty ? line : context.joined(separator: "\n") + "\n\u{2192} " + line
    }

    /// Strict, defensive decoding: unknown relations and empty names are dropped later by the assembler.
    static func decode(_ content: String) throws -> LineParse {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let data = String(content[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            NSLog("%@", "[LineParse] unreadable reply: \(content.prefix(300))")
            #endif
            throw LineParseError.unreadable
        }
        func str(_ dict: [String: Any], _ key: String, max: Int) -> String {
            String((dict[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        }
        func minutes(_ value: Any?) -> Int? {
            guard let v = (value as? NSNumber)?.intValue ?? (value as? String).flatMap({ Int($0) }) else { return nil }
            return Swift.min(Swift.max(v, 0), 24 * 60)
        }
        /// "the thyroid", "my iron" → "thyroid", "iron": the same medication as the line that names it.
        func name(_ dict: [String: Any], _ key: String) -> String {
            var s = str(dict, key, max: 60)
            for prefix in ["the ", "my ", "taking "] where s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return canonicalTimeOfDay(s)
        }
        var result = LineParse()
        for raw in (json["meds"] as? [[String: Any]] ?? []).prefix(8) {
            let name = name(raw, "name")
            guard !name.isEmpty else { continue }
            var med = LineParse.Med(name: name, dose: str(raw, "dose", max: 40))
            let parts = str(raw, "time", max: 5).split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) {
                med.time = DoseTime(hour: parts[0], minute: parts[1])
            }
            result.meds.append(med)
        }
        for raw in (json["rules"] as? [[String: Any]] ?? []).prefix(12) {
            let subject = name(raw, "subject")
            guard !subject.isEmpty else { continue }
            let target = name(raw, "target")
            result.rules.append(LineParse.Rule(subject: subject, relation: str(raw, "relation", max: 12).lowercased(),
                                               targetType: str(raw, "targetType", max: 12).lowercased(),
                                               target: target.isEmpty ? nil : target,
                                               min: minutes(raw["min"]), max: minutes(raw["max"])))
        }
        result.needsContext = (json["needsContext"] as? Bool) ?? false
        // A rule's subject must be one of the line's medications; otherwise the model guessed one.
        let medNames = Set(result.meds.map { $0.name.lowercased() })
        result.rules.removeAll { !medNames.contains($0.subject.lowercased()) }
        // No medication at all: it is about a medication named further up.
        if result.meds.isEmpty { result.needsContext = true }
        return result
    }

    /// "Progesterone a.m." / "progesterone am" → "Progesterone AM", so the same medication matches across lines.
    static func canonicalTimeOfDay(_ name: String) -> String {
        let patterns = [(#"(?i)\s*\ba\.?\s?m\.?$"#, " AM"), (#"(?i)\s*\bp\.?\s?m\.?$"#, " PM")]
        for (pattern, suffix) in patterns {
            if let range = name.range(of: pattern, options: .regularExpression), range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) + suffix
            }
        }
        return name
    }

    /// The model sometimes drops "a.m."/"p.m." ("Progesterone a.m." → "Progesterone"), which would make it a
    /// different medication from "Progesterone AM" on the next line. Put it back when the line says it.
    static func restoreTimeOfDay(_ parse: LineParse, line: String, context: [String] = []) -> LineParse {
        var out = parse
        let lower = line.lowercased()
        func suffix(of name: String, in text: String) -> String? {
            let escaped = NSRegularExpression.escapedPattern(for: name.lowercased())
            let am = text.range(of: escaped + #"\s*a\.?\s?m\b\.?"#, options: .regularExpression) != nil
            let pm = text.range(of: escaped + #"\s*p\.?\s?m\b\.?"#, options: .regularExpression) != nil
            return am == pm ? nil : (am ? " AM" : " PM")
        }
        // "Progesterone a.m." above, "apart from progesterone p.m." here, and the model wrote "progesterone" for
        // both: the subject is the one above, the target the one on this line.
        let contextText = context.joined(separator: "\n").lowercased()
        for r in out.rules.indices where out.rules[r].targetType == "medication" {
            let rule = out.rules[r]
            guard let target = rule.target, target.caseInsensitiveCompare(rule.subject) == .orderedSame,
                  canonicalTimeOfDay(target) == target,
                  let here = suffix(of: target, in: lower), let above = suffix(of: target, in: contextText), here != above
            else { continue }
            out.rules[r].subject = rule.subject + above
            out.rules[r].target = target + here
            out.meds.removeAll { $0.name.caseInsensitiveCompare(target) == .orderedSame }
            for name in [rule.subject + above, target + here]
            where !out.meds.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                out.meds.append(LineParse.Med(name: name))
            }
        }
        for i in out.meds.indices {
            let name = out.meds[i].name
            guard canonicalTimeOfDay(name) == name, !name.hasSuffix(" AM"), !name.hasSuffix(" PM") else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: name.lowercased())
            let am = lower.range(of: escaped + #"\s*a\.?\s?m\b\.?"#, options: .regularExpression) != nil
            let pm = lower.range(of: escaped + #"\s*p\.?\s?m\b\.?"#, options: .regularExpression) != nil
            guard am != pm else { continue }
            let fixed = name + (am ? " AM" : " PM")
            // Already listed with its time of day: this bare one is a duplicate.
            if out.meds.contains(where: { $0.name.caseInsensitiveCompare(fixed) == .orderedSame }) { continue }
            out.meds[i].name = fixed
            for r in out.rules.indices {
                if out.rules[r].subject.caseInsensitiveCompare(name) == .orderedSame { out.rules[r].subject = fixed }
                if out.rules[r].target?.caseInsensitiveCompare(name) == .orderedSame { out.rules[r].target = fixed }
            }
        }
        return out
    }

    /// Drops rules the model guessed rather than read, so a follow-on line is never mistaken for one that names
    /// its own medication:
    /// - a medication rule with no target, or with itself as target; a meal rule with no meal;
    /// - a subject that appears in the line only as a target ("at least 4 h after taking **the thyroid**",
    ///   "apart from **progesterone p.m.**").
    static func validated(_ parse: LineParse, line: String) -> LineParse {
        var out = parse
        /// "Progesterone p.m." / "progesterone pm" → "progesterone pm", single-spaced.
        func plain(_ text: String) -> String {
            let t = text.lowercased().replacingOccurrences(of: #"\b([ap])\s?\.\s?m\b\.?"#, with: "$1m", options: .regularExpression)
            return t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let lower = " " + plain(line) + " "
        let targetWords: Set<String> = ["after", "before", "from", "taking", "than", "following"]
        func onlyAsTarget(_ name: String) -> Bool {
            let n = plain(name)
            for c in [n] where c.count >= 3 {
                var positions: [String.Index] = []
                var from = lower.startIndex
                while let r = lower.range(of: " " + c, range: from..<lower.endIndex) {
                    positions.append(r.lowerBound); from = r.upperBound
                }
                guard !positions.isEmpty else { continue }
                return positions.allSatisfy { pos in
                    let before = lower[..<pos].split(whereSeparator: { !$0.isLetter }).suffix(2).map(String.init)
                    return before.contains { targetWords.contains($0) }
                }
            }
            return false // not in the line at all: it came from Context, which is fine
        }
        // "apart" and "with" work both ways: if the model made the target the subject, turn the rule round.
        for i in out.rules.indices where ["apart", "with"].contains(out.rules[i].relation) && out.rules[i].targetType == "medication" {
            let rule = out.rules[i]
            guard let target = rule.target, !target.isEmpty, onlyAsTarget(rule.subject), !onlyAsTarget(target) else { continue }
            out.rules[i].subject = target
            out.rules[i].target = rule.subject
            if !out.meds.contains(where: { canonicalTimeOfDay($0.name).lowercased() == canonicalTimeOfDay(target).lowercased() }) {
                out.meds.insert(LineParse.Med(name: target), at: 0)
            }
        }
        out.rules.removeAll { rule in
            let relation = rule.relation, type = rule.targetType
            if type == "medication" {
                guard let t = rule.target, !t.isEmpty,
                      canonicalTimeOfDay(t).lowercased() != canonicalTimeOfDay(rule.subject).lowercased() else { return true }
            }
            if type == "meal", (rule.target ?? "").isEmpty { return true }
            if relation == "apart", (rule.min ?? 0) == 0 { return true }
            return onlyAsTarget(rule.subject)
        }
        return out
    }

    /// One request; `attempt` 0 uses the fast model, the retry uses the fallback.
    @MainActor
    static func liveTransport(line: String, context: [String], known: [String], attempt: Int) async throws -> String {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        guard !base.isEmpty, !secret.isEmpty, let url = URL(string: "\(base)/v2/vercel/v1/chat/completions") else {
            throw LineParseError.notConfigured
        }
        let body: [String: Any] = [
            "model": attempt == 0 ? model : fallbackModel,
            "temperature": 0,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            // Both models reason by default; on longer lines that used ~1,800 hidden tokens, ran past the cap
            // and came back empty. Reading one line needs no reasoning.
            "reasoning": ["enabled": false],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(line: line, context: context, known: known)],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = attempt == 0 ? timeout : fallbackTimeout
        let (data, _) = try await sendWithRetry(request, maxAttempts: 1)
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              !content.isEmpty else { throw ProxyError.noData }
        return content
    }
}

// MARK: - Parser with a per-line cache

/// Reads lines in parallel and remembers every line it has read, so editing one line re-reads only that line.
///
/// A line that doesn't say which medication it is about ("30 minutes afterwards I can't have any food") borrows
/// one from the lines above it: it is read again with them as context, from the nearest line above that names a
/// medication down to it. A blank line is a break; context never crosses it. That second read is cached under the
/// line plus its context, so editing the line above re-reads the follow-on line too, and nothing else.
@MainActor
@Observable
final class LineParser {
    typealias Transport = @Sendable (_ line: String, _ context: [String], _ known: [String], _ attempt: Int) async throws -> String

    /// Lines (normalized) being read right now: the editor shimmers next to them.
    private(set) var reading: Set<String> = []
    /// Lines that could not be read, with a short reason.
    private(set) var failed: [String: String] = [:]
    /// Requests sent (tests count these).
    private(set) var callCount = 0
    /// Wall time of the last batch that sent anything.
    private(set) var lastDuration: Duration?

    @ObservationIgnored private var cache: [String: LineParse] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let defaults: UserDefaults?
    private static let cacheKey = "bloom.lineParseCache.v8"
    private static let cacheLimit = 300
    /// At most this many lines above are sent as context.
    static let maxContextLines = 4

    init(transport: @escaping Transport = { try await LineParseService.liveTransport(line: $0, context: $1, known: $2, attempt: $3) },
         defaults: UserDefaults? = .standard) {
        self.transport = transport
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.cacheKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in stored { cache[entry.line] = entry.parse; cacheOrder.append(entry.line) }
        }
    }

    private struct Entry: Codable { var line: String; var parse: LineParse }

    /// The line read on its own.
    func cached(_ line: String) -> LineParse? { cache[LineParseService.normalize(line)] }

    /// What each line means, by its index in `lines` (blank lines included), with context applied.
    /// Lines still being read are missing.
    func resolved(_ lines: [String]) -> [Int: LineParse] {
        var out: [Int: LineParse] = [:]
        for (index, request) in Self.requests(for: lines, cache: cache) {
            if let p = cache[request.key] { out[index] = p }
        }
        return out
    }

    /// True when every non-empty line is understood (with its context, where it needs one).
    func isUpToDate(_ lines: [String]) -> Bool {
        let plain = lines.map(LineParseService.normalize).filter { !$0.isEmpty }
        guard plain.allSatisfy({ cache[$0] != nil }) else { return false }
        return Self.requests(for: lines, cache: cache).allSatisfy { cache[$0.1.key] != nil }
    }

    /// True when this line (by index) is waiting for its context read.
    func isReading(index: Int, in lines: [String]) -> Bool {
        guard let request = Self.requests(for: lines, cache: cache).first(where: { $0.0 == index })?.1 else { return false }
        return reading.contains(request.key) || reading.contains(request.line)
    }

    struct Request: Equatable {
        var line: String
        var context: [String]
        var key: String { LineParseService.contextKey(line, context: context) }
    }

    /// The read each non-empty line needs: on its own, or, once its own read says it needs context, with the
    /// lines above it up to the nearest one that names a medication (never across a blank line).
    static func requests(for lines: [String], cache: [String: LineParse]) -> [(Int, Request)] {
        let plain = lines.map(LineParseService.normalize)
        var out: [(Int, Request)] = []
        for (i, line) in plain.enumerated() where !line.isEmpty {
            guard let own = cache[line], own.needsContext else {
                out.append((i, Request(line: line, context: [])))
                continue
            }
            var context: [String] = []
            var j = i - 1
            var anchored = false
            while j >= 0, !plain[j].isEmpty, context.count < maxContextLines {
                context.insert(plain[j], at: 0)
                if cache[plain[j]]?.namesSubject == true { anchored = true; break }
                j -= 1
            }
            // No medication named above in this block: keep the line's own read (it will show a problem).
            out.append((i, Request(line: line, context: anchored ? context : [])))
        }
        return out
    }

    /// Reads what's missing: every changed line on its own, all at once; then, also at once, the lines that need
    /// the lines above them. Returns what every line means, by index.
    @discardableResult
    func parse(lines: [String], known: [String], holding: Set<String> = []) async -> [Int: LineParse] {
        let clock = ContinuousClock()
        let started = clock.now
        var sent = 0

        // Pass 1: each line on its own.
        let plain = Array(NSOrderedSet(array: lines.map(LineParseService.normalize).filter { !$0.isEmpty })) as? [String] ?? []
        let firstPass = plain.filter { cache[$0] == nil && !reading.contains($0) && !holding.contains($0) }
            .map { Request(line: $0, context: []) }
        sent += await read(firstPass, known: known)

        // Pass 2: lines that need context, with it.
        let secondPass = Self.requests(for: lines, cache: cache).map(\.1)
            .filter { !$0.context.isEmpty && cache[$0.key] == nil && !reading.contains($0.key)
                && !holding.contains($0.line) && $0.context.allSatisfy { !holding.contains($0) } }
        var seen = Set<String>()
        sent += await read(secondPass.filter { seen.insert($0.key).inserted }, known: known)

        if sent > 0 {
            lastDuration = clock.now - started
            NSLog("%@", "[LineParse] \(sent) read(s) (\(firstPass.count) line(s), \(seen.count) with context) in \(lastDuration!.formatted(.units(allowed: [.seconds, .milliseconds])))")
            persist()
        }
        return resolved(lines)
    }

    /// Sends these reads in parallel (one retry each on the fallback model). Returns how many were sent.
    private func read(_ requests: [Request], known: [String]) async -> Int {
        guard !requests.isEmpty else { return 0 }
        let keys = requests.map(\.key)
        reading.formUnion(keys)
        for key in keys { failed[key] = nil }
        callCount += requests.count
        let transport = self.transport
        let results = await withTaskGroup(of: (Request, Result<LineParse, Error>).self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let reply = try await transport(request.line, request.context, known, 0)
                        #if DEBUG
                        NSLog("%@", "[LineParse] reply \(request.context.isEmpty ? "alone" : "ctx") · \(request.line.prefix(30)) → \(reply.prefix(400))")
                        #endif
                        let parse = try LineParseService.decode(reply)
                        // Given the medication above, a follow-on line should yield a rule. If the fast model still
                        // found none, ask the fallback once.
                        if !request.context.isEmpty,
                           LineParseService.validated(LineParseService.restoreTimeOfDay(parse, line: request.line, context: request.context), line: request.line).rules.isEmpty {
                            NSLog("%@", "[LineParse] no rule with context, asking the fallback · \(request.line.prefix(40))")
                            if let second = try? LineParseService.decode(try await transport(request.line, request.context, known, 1)) {
                                return (request, .success(second))
                            }
                        }
                        return (request, .success(parse))
                    } catch is CancellationError {
                        return (request, .failure(CancellationError()))
                    } catch {
                        NSLog("%@", "[LineParse] attempt 0 failed: \(error) · \(request.line.prefix(40))")
                        do {
                            return (request, .success(try LineParseService.decode(try await transport(request.line, request.context, known, 1))))
                        } catch {
                            NSLog("%@", "[LineParse] attempt 1 failed: \(error) · \(request.line.prefix(40))")
                            return (request, .failure(error))
                        }
                    }
                }
            }
            var all: [(Request, Result<LineParse, Error>)] = []
            for await item in group { all.append(item) }
            return all
        }
        for (request, result) in results {
            reading.remove(request.key)
            switch result {
            case .success(var parse):
                parse = LineParseService.validated(LineParseService.restoreTimeOfDay(parse, line: request.line, context: request.context), line: request.line)
                if request.context.isEmpty, parse.rules.isEmpty, Self.soundsLikeARule(request.line) { parse.needsContext = true }
                if !request.context.isEmpty { parse.needsContext = false }
                store(parse, for: request.key)
            case .failure(let error):
                if !(error is CancellationError) {
                    failed[request.line] = (error as? LineParseError) == .notConfigured
                        ? "Reading isn't available right now."
                        : "Couldn't read this line. Tap to try again."
                }
            }
        }
        return requests.count
    }

    /// "approximately 10 to 12 hours apart from progesterone p.m." names a medication but no rule could be read
    /// without knowing what it's apart from: treat timing words with no rule as needing the line above.
    static func soundsLikeARule(_ line: String) -> Bool {
        let lower = line.lowercased()
        let words = ["apart", "after", "before", "hour", "minute", " min", "food", "eat", "meal", "breakfast", "lunch",
                     "dinner", "snack", "bed", "wake", "within", "together", "same time"]
        return words.contains { lower.contains($0) }
    }

    /// Forgets this line, and its reads with context.
    func forget(_ line: String) {
        let key = LineParseService.normalize(line)
        let suffix = "\u{2192} " + key
        for k in cache.keys where k == key || k.hasSuffix(suffix) { cache[k] = nil }
        cacheOrder.removeAll { $0 == key || $0.hasSuffix(suffix) }
        failed[key] = nil
        persist()
    }

    private func store(_ parse: LineParse, for key: String) {
        cache[key] = parse
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    private func persist() {
        guard let defaults else { return }
        let entries = cacheOrder.compactMap { line in cache[line].map { Entry(line: line, parse: $0) } }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.cacheKey) }
    }
}

// MARK: - From lines to one regimen

/// Pure: turns parsed lines into medication drafts (first-mention order), rules and a per-line summary.
@MainActor
enum RegimenAssembler {
    struct Existing: Equatable {
        var id: UUID
        var name: String
        var friendlyName: String
    }

    struct LineSummary: Equatable, Identifiable {
        var index: Int
        var text: String
        /// "Iron · at least 4 h after Thyroid", one per rule (or one per medication with no rule).
        var items: [String]
        /// Draft ids named on this line.
        var medIDs: [UUID]
        /// Rule ids read from this line.
        var ruleIDs: [UUID]
        /// Something this line says that Bloom can't use.
        var problem: String?
        var id: Int { index }
    }

    struct Result: Equatable {
        var drafts: [RegimenMedDraft]
        var rules: [ScheduleRule]
        var lines: [LineSummary]
        /// Draft id → place in her text (0 = first named).
        var order: [UUID: Int]
    }

    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    /// `parses` is keyed by `LineParseService.normalize(line)` (each line read on its own).
    static func assemble(text: String, parses: [String: LineParse], existing: [Existing]) -> Result {
        var byIndex: [Int: LineParse] = [:]
        for (i, line) in lines(of: text).enumerated() {
            if let p = parses[LineParseService.normalize(line)] { byIndex[i] = p }
        }
        return assemble(text: text, lineParses: byIndex, existing: existing)
    }

    /// `lineParses` is keyed by line index (`LineParser.resolved`). Lines without a parse are skipped (still reading).
    static func assemble(text: String, lineParses: [Int: LineParse], existing: [Existing]) -> Result {
        var drafts: [RegimenMedDraft] = []
        var byName: [String: UUID] = [:]
        var rules: [ScheduleRule] = []
        var summaries: [LineSummary] = []
        var namesForDescribe: [UUID: String] = [:]
        /// Summary index → medications named there with no rule on that line (filled in once all lines are read).
        var unruledByLine: [Int: [UUID]] = [:]
        /// The first line each medication owns (its own name line, or a rule about it). Her order follows this,
        /// so "Thyroid at least 4 h before Prenatal vitamin" doesn't pull Prenatal vitamin up to second.
        var ownLine: [UUID: Int] = [:]

        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func resolve(_ rawName: String, line: String, dose: String = "", time: DoseTime? = nil, create: Bool) -> UUID? {
            let k = key(rawName)
            guard !k.isEmpty else { return nil }
            if let id = byName[k] {
                if let i = drafts.firstIndex(where: { $0.id == id }) {
                    if drafts[i].dose.isEmpty { drafts[i].dose = MedParseService.verifiedDosePart(dose, in: line) }
                    if drafts[i].fixedTime == nil, let time, line.contains(where: \.isNumber) { drafts[i].fixedTime = time }
                }
                return id
            }
            guard create else { return nil }
            var draft: RegimenMedDraft
            if let match = existing.first(where: { key($0.name) == k || (!$0.friendlyName.isEmpty && key($0.friendlyName) == k) }) {
                if let already = drafts.first(where: { $0.existingID == match.id }) {
                    byName[k] = already.id
                    return already.id
                }
                draft = RegimenMedDraft(name: match.name, friendlyName: match.friendlyName, existingID: match.id)
                byName[key(match.name)] = draft.id
                if !match.friendlyName.isEmpty { byName[key(match.friendlyName)] = draft.id }
            } else {
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = RegimenMedDraft(name: trimmed.prefix(1).uppercased() + trimmed.dropFirst())
            }
            draft.dose = MedParseService.verifiedDosePart(dose, in: line)
            if let time, line.contains(where: \.isNumber) { draft.fixedTime = time }
            byName[k] = draft.id
            drafts.append(draft)
            namesForDescribe[draft.id] = draft.shortName
            return draft.id
        }

        for (index, rawLine) in lines(of: text).enumerated() {
            let line = LineParseService.normalize(rawLine)
            guard !line.isEmpty, let parse = lineParses[index] else { continue }
            var summary = LineSummary(index: index, text: line, items: [], medIDs: [], ruleIDs: [])
            var introduced: [UUID] = []
            for med in parse.meds {
                let before = drafts.count
                guard let id = resolve(med.name, line: line, dose: med.dose, time: med.time, create: true) else { continue }
                if drafts.count > before { introduced.append(id) }
                if !summary.medIDs.contains(id) { summary.medIDs.append(id) }
                if parse.meds.count == 1, ownLine[id] == nil { ownLine[id] = index }
            }
            var ruled = Set<UUID>()
            for raw in parse.rules {
                guard let subject = resolve(raw.subject, line: line, create: true),
                      let relation = RuleRelation(rawValue: raw.relation),
                      let target = RuleTarget(rawValue: raw.targetType) else { continue }
                if !summary.medIDs.contains(subject) { summary.medIDs.append(subject) }
                if ownLine[subject] == nil { ownLine[subject] = index }
                var rule = ScheduleRule(subjectID: subject, relation: relation, target: target,
                                        minMinutes: raw.min, maxMinutes: raw.max, sourceText: line)
                switch target {
                case .medication:
                    guard let t = raw.target, let other = resolve(t, line: line, create: true), other != subject else { continue }
                    if !summary.medIDs.contains(other) { summary.medIDs.append(other) }
                    rule.targetMedicationID = other
                case .meal:
                    guard let meal = raw.target?.trimmingCharacters(in: .whitespaces), !meal.isEmpty else { continue }
                    rule.targetMeal = meal.capitalized
                case .food, .wake, .bed:
                    break
                }
                // "with" means a meal, food or another medication ("Calcium with Prenatal AM"); never wake or bed.
                if relation == .with, target == .wake || target == .bed { continue }
                // "before bed" / "after waking" with no gap is the same instruction as "at bedtime" / "on waking";
                // one form keeps her text and the plan saying the same thing (and start over finds nothing changed).
                if relation == .before || relation == .after, target == .wake || target == .bed,
                   (rule.minMinutes ?? 0) == 0, rule.maxMinutes == nil {
                    rule.relation = .at
                    rule.minMinutes = 0
                }
                if let lo = rule.minMinutes, let hi = rule.maxMinutes, hi < lo { rule.maxMinutes = nil }
                if relation == .apart, (rule.minMinutes ?? 0) == 0 { continue }
                if rules.contains(where: { $0.subjectID == rule.subjectID && $0.relation == rule.relation && $0.target == rule.target
                    && $0.targetMedicationID == rule.targetMedicationID && $0.targetMeal == rule.targetMeal
                    && $0.minMinutes == rule.minMinutes && $0.maxMinutes == rule.maxMinutes }) { continue }
                rules.append(rule)
                summary.ruleIDs.append(rule.id)
                ruled.insert(subject)
                // Named inside this rule ("together with Prenatal AM"), so no separate "placed by your routine".
                if let other = rule.targetMedicationID { ruled.insert(other) }
            }
            for rule in rules where summary.ruleIDs.contains(rule.id) {
                summary.items.append(ScheduleEngine.describe(rule, names: namesForDescribe))
            }
            let unruled = introduced.filter { !ruled.contains($0) }
            if !unruled.isEmpty { unruledByLine[summaries.count] = unruled }
            if parse.needsContext, summary.ruleIDs.isEmpty {
                summary.problem = "Which medication is this about? Start the line with its name, or put it under that medication's line."
            } else if summary.medIDs.isEmpty {
                summary.problem = "No medication named on this line."
            }
            summaries.append(summary)
        }
        // A name on its own ("Iron") whose rules are on the lines under it.
        let ruledAnywhere = Set(rules.flatMap { [$0.subjectID] + ($0.targetMedicationID.map { [$0] } ?? []) })
        for (i, ids) in unruledByLine where summaries[i].problem == nil {
            for id in ids {
                guard let draft = drafts.first(where: { $0.id == id }) else { continue }
                if let fixed = draft.fixedTime {
                    summaries[i].items.append("\(draft.shortName) · at \(ScheduleEngine.clock(fixed.minutesFromMidnight))")
                } else if ruledAnywhere.contains(id) {
                    summaries[i].items.append("\(draft.shortName) · rules on the lines below")
                } else {
                    summaries[i].items.append("\(draft.shortName) · placed by your routine")
                }
            }
        }
        for i in summaries.indices where summaries[i].problem == nil && summaries[i].items.isEmpty {
            summaries[i].problem = "Bloom couldn't find a timing rule here."
        }
        // Stable: medications that never own a line keep their first-mention place after the rest.
        drafts = drafts.enumerated()
            .sorted { (ownLine[$0.element.id] ?? Int.max, $0.offset) < (ownLine[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        let order = Dictionary(uniqueKeysWithValues: drafts.enumerated().map { ($1.id, $0) })
        return Result(drafts: drafts, rules: rules, lines: summaries, order: order)
    }
}
