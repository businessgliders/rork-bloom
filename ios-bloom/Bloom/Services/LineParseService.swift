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
    static let timeout: TimeInterval = 15
    static let maxTokens = 400

    static let systemPrompt = """
    Parse one line a pregnant person wrote about medications her clinician prescribed. Only parse; never suggest times, doses or advice.
    Return JSON: {"meds":[{"name":str,"dose":str,"time":"HH:mm"|null}],"rules":[{"subject":str,"relation":"before"|"after"|"apart"|"with"|"at","targetType":"medication"|"food"|"meal"|"wake"|"bed","target":str|null,"min":int|null,"max":int|null}]}
    - meds: every medication named in the line. Use the exact Known name when it matches (case-insensitive); else the name as written. dose only if literally written, else "". time only for an exact clock time written.
    - subject/target: med names from meds. target is a meal name ("breakfast","lunch","dinner","snack") for meal, else null.
    - Minutes: "as soon as I wake" = at wake 0. "30 min after waking" = after wake 30. "no food for 30 min after" = before food 30. "no food 1 h before" = after food 60. "no food 1 h before or after" = apart food 60. "with lunch" = with meal lunch. "with food" = with food. "X 4 h after Y" = X after medication Y 240. "X and Y 2 h apart" = X apart medication Y 120. "X with Y" (Y a medication) = X with medication Y 0. "before bed" = before bed 0. "at bedtime" = at bed 0.
    - Only rules actually written. Empty arrays if none.
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

    static func userMessage(line: String, known: [String]) -> String {
        "Known: \(known.isEmpty ? "none" : known.joined(separator: ", "))\nLine: \(String(line.prefix(400)))"
    }

    /// Strict, defensive decoding: unknown relations and empty names are dropped later by the assembler.
    static func decode(_ content: String) throws -> LineParse {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let data = String(content[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LineParseError.unreadable
        }
        func str(_ dict: [String: Any], _ key: String, max: Int) -> String {
            String((dict[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        }
        func minutes(_ value: Any?) -> Int? {
            guard let v = (value as? NSNumber)?.intValue ?? (value as? String).flatMap({ Int($0) }) else { return nil }
            return Swift.min(Swift.max(v, 0), 24 * 60)
        }
        var result = LineParse()
        for raw in (json["meds"] as? [[String: Any]] ?? []).prefix(8) {
            let name = str(raw, "name", max: 60)
            guard !name.isEmpty else { continue }
            var med = LineParse.Med(name: name, dose: str(raw, "dose", max: 40))
            let parts = str(raw, "time", max: 5).split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) {
                med.time = DoseTime(hour: parts[0], minute: parts[1])
            }
            result.meds.append(med)
        }
        for raw in (json["rules"] as? [[String: Any]] ?? []).prefix(12) {
            let subject = str(raw, "subject", max: 60)
            guard !subject.isEmpty else { continue }
            let target = str(raw, "target", max: 60)
            result.rules.append(LineParse.Rule(subject: subject, relation: str(raw, "relation", max: 12).lowercased(),
                                               targetType: str(raw, "targetType", max: 12).lowercased(),
                                               target: target.isEmpty ? nil : target,
                                               min: minutes(raw["min"]), max: minutes(raw["max"])))
        }
        return result
    }

    /// One request; `attempt` 0 uses the fast model, the retry uses the fallback.
    @MainActor
    static func liveTransport(line: String, known: [String], attempt: Int) async throws -> String {
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
                ["role": "user", "content": userMessage(line: line, known: known)],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
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
@MainActor
@Observable
final class LineParser {
    typealias Transport = @Sendable (_ line: String, _ known: [String], _ attempt: Int) async throws -> String

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
    private static let cacheKey = "bloom.lineParseCache.v2"
    private static let cacheLimit = 200

    init(transport: @escaping Transport = { try await LineParseService.liveTransport(line: $0, known: $1, attempt: $2) },
         defaults: UserDefaults? = .standard) {
        self.transport = transport
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.cacheKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in stored { cache[entry.line] = entry.parse; cacheOrder.append(entry.line) }
        }
    }

    private struct Entry: Codable { var line: String; var parse: LineParse }

    func cached(_ line: String) -> LineParse? { cache[LineParseService.normalize(line)] }

    /// True when every non-empty line is already understood.
    func isUpToDate(_ lines: [String]) -> Bool {
        lines.map(LineParseService.normalize).filter { !$0.isEmpty }.allSatisfy { cache[$0] != nil }
    }

    /// Reads the lines not in the cache, all at once. Returns every line it understands, keyed by normalized text.
    @discardableResult
    func parse(lines: [String], known: [String]) async -> [String: LineParse] {
        let wanted = Array(NSOrderedSet(array: lines.map(LineParseService.normalize).filter { !$0.isEmpty })) as? [String] ?? []
        let missing = wanted.filter { cache[$0] == nil && !reading.contains($0) }
        if !missing.isEmpty {
            reading.formUnion(missing)
            for line in missing { failed[line] = nil }
            callCount += missing.count
            let transport = self.transport
            let clock = ContinuousClock()
            let started = clock.now
            let results = await withTaskGroup(of: (String, Result<LineParse, Error>).self) { group in
                for line in missing {
                    group.addTask {
                        do {
                            return (line, .success(try LineParseService.decode(try await transport(line, known, 0))))
                        } catch is CancellationError {
                            return (line, .failure(CancellationError()))
                        } catch {
                            print("[LineParse] attempt 0 failed: \(error) · \(line.prefix(40))")
                            do {
                                return (line, .success(try LineParseService.decode(try await transport(line, known, 1))))
                            } catch {
                                print("[LineParse] attempt 1 failed: \(error) · \(line.prefix(40))")
                                return (line, .failure(error))
                            }
                        }
                    }
                }
                var all: [(String, Result<LineParse, Error>)] = []
                for await item in group { all.append(item) }
                return all
            }
            lastDuration = clock.now - started
            print("[LineParse] \(missing.count) line(s) in \(lastDuration!.formatted(.units(allowed: [.seconds, .milliseconds])))")
            for (line, result) in results {
                reading.remove(line)
                switch result {
                case .success(let parse): store(parse, for: line)
                case .failure(let error):
                    if !(error is CancellationError) {
                        failed[line] = (error as? LineParseError) == .notConfigured
                            ? "Reading isn't available right now."
                            : "Couldn't read this line. Tap to try again."
                    }
                }
            }
            persist()
        }
        return wanted.reduce(into: [:]) { out, line in if let p = cache[line] { out[line] = p } }
    }

    func forget(_ line: String) {
        let key = LineParseService.normalize(line)
        cache[key] = nil
        cacheOrder.removeAll { $0 == key }
        failed[key] = nil
        persist()
    }

    private func store(_ parse: LineParse, for line: String) {
        cache[line] = parse
        cacheOrder.removeAll { $0 == line }
        cacheOrder.append(line)
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

    /// `parses` is keyed by `LineParseService.normalize(line)`. Lines without a parse are skipped (still reading).
    static func assemble(text: String, parses: [String: LineParse], existing: [Existing]) -> Result {
        var drafts: [RegimenMedDraft] = []
        var byName: [String: UUID] = [:]
        var rules: [ScheduleRule] = []
        var summaries: [LineSummary] = []
        var namesForDescribe: [UUID: String] = [:]

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
            guard !line.isEmpty, let parse = parses[line] else { continue }
            var summary = LineSummary(index: index, text: line, items: [], medIDs: [], ruleIDs: [])
            var introduced: [UUID] = []
            for med in parse.meds {
                let before = drafts.count
                guard let id = resolve(med.name, line: line, dose: med.dose, time: med.time, create: true) else { continue }
                if drafts.count > before { introduced.append(id) }
                if !summary.medIDs.contains(id) { summary.medIDs.append(id) }
            }
            var ruled = Set<UUID>()
            for raw in parse.rules {
                guard let subject = resolve(raw.subject, line: line, create: true),
                      let relation = RuleRelation(rawValue: raw.relation),
                      let target = RuleTarget(rawValue: raw.targetType) else { continue }
                if !summary.medIDs.contains(subject) { summary.medIDs.append(subject) }
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
            for id in introduced where !ruled.contains(id) {
                guard let draft = drafts.first(where: { $0.id == id }) else { continue }
                if let fixed = draft.fixedTime {
                    summary.items.append("\(draft.shortName) · at \(ScheduleEngine.clock(fixed.minutesFromMidnight))")
                } else {
                    summary.items.append("\(draft.shortName) · placed by your routine")
                }
            }
            if summary.medIDs.isEmpty {
                summary.problem = "No medication named on this line."
            } else if summary.items.isEmpty {
                summary.problem = "Bloom couldn't find a timing rule here."
            }
            summaries.append(summary)
        }
        let order = Dictionary(uniqueKeysWithValues: drafts.enumerated().map { ($1.id, $0) })
        return Result(drafts: drafts, rules: rules, lines: summaries, order: order)
    }
}
