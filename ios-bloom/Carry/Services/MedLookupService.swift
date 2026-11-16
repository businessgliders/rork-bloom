import Foundation

/// General timing information the AI suggests for a medication. Never includes dosing.
/// Nothing is applied until the user confirms it in the form.
struct MedSuggestion: Equatable {
    var recognized: Bool
    var displayName: String
    var kind: String
    var foodRule: FoodRule
    var noFoodBeforeMinutes: Int
    var noFoodAfterMinutes: Int
    var preferredSlot: DaySlot?
    var tip: String
}

/// Looks up general timing guidance for a medication name through the Rork AI proxy
/// (Rork → Vercel AI Gateway → Google Gemini). Only the name is sent.
enum MedLookupService {
    static let model = "google/gemini-3.8-flash"

    enum LookupError: LocalizedError {
        case notConfigured
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Suggestions aren't available in this build. You can still fill it in yourself."
            case .unreadable: "Couldn't read a suggestion this time. You can fill it in yourself or try again."
            }
        }
    }

    private static let systemPrompt = """
    You help a pregnant person set up reminders for a medication or supplement their clinician already prescribed. \
    Given only a product name, return GENERAL label-level timing information as a JSON object with exactly these keys:
    {"recognized": boolean, "displayName": string, "kind": string (e.g. "thyroid hormone", "prenatal vitamin", "iron supplement"), \
    "foodRule": "empty_stomach" | "with_food" | "any", "noFoodBeforeMinutes": integer 0-240, "noFoodAfterMinutes": integer 0-240, \
    "preferredSlot": "morning" | "afternoon" | "evening" | "any", "tip": string, max 120 characters}
    Rules: Never mention doses, amounts, strengths, frequency or whether to take, stop or change a medication. \
    Never give pregnancy safety judgements. Use 0 minutes unless the label commonly advises an empty stomach. \
    If you don't recognise the name, set recognized to false, foodRule to "any" and both minutes to 0. Reply with JSON only.
    """

    static func lookup(name: String) async throws -> MedSuggestion {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        guard !base.isEmpty, !secret.isEmpty, let url = URL(string: "\(base)/v2/vercel/v1/chat/completions") else {
            throw LookupError.notConfigured
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Medication name: \(name.prefix(80))"],
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
        return try parse(content, fallbackName: name)
    }

    /// Defensive parsing: strips code fences/prose and clamps every value.
    static func parse(_ text: String, fallbackName: String) throws -> MedSuggestion {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookupError.unreadable
        }

        func int(_ key: String) -> Int {
            let value = (json[key] as? NSNumber)?.intValue ?? Int(json[key] as? String ?? "") ?? 0
            return min(max(value, 0), 240)
        }

        let recognized = json["recognized"] as? Bool ?? true
        var rule = FoodRule(rawValue: (json["foodRule"] as? String ?? "any").lowercased()) ?? .any
        var before = int("noFoodBeforeMinutes")
        var after = int("noFoodAfterMinutes")
        if !recognized { rule = .any }
        if rule != .emptyStomach { before = 0; after = 0 }

        let slotString = (json["preferredSlot"] as? String ?? "any").lowercased()
        let tip = (json["tip"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (json["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return MedSuggestion(
            recognized: recognized,
            displayName: display.isEmpty ? fallbackName : String(display.prefix(60)),
            kind: String((json["kind"] as? String ?? "").prefix(40)),
            foodRule: rule,
            noFoodBeforeMinutes: before,
            noFoodAfterMinutes: after,
            preferredSlot: DaySlot(rawValue: slotString),
            tip: String(tip.prefix(140))
        )
    }
}

// MARK: - Proxy transport (shared retry wrapper)

enum ProxyError: LocalizedError {
    case authError
    case insufficientBalance
    case payloadTooLarge
    case rateLimited
    case serverError(Int)
    case clientError(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .authError:           "AI features are currently unavailable. Please restart the app."
        case .insufficientBalance: "AI features are temporarily unavailable. Please try again later."
        case .payloadTooLarge:     "Image is too large. Please try a smaller photo."
        case .rateLimited:         "Too many requests. Please wait a moment and try again."
        case .serverError:         "Something went wrong. Please try again."
        case .clientError:         "Something went wrong. Please try again."
        case .noData:              "No response from the AI service. Please try again."
        }
    }
}

func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
        return max(0, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: value) {
        return max(0, date.timeIntervalSinceNow)
    }
    return nil
}

func exponentialDelay(attempt: Int) -> Double {
    let base = pow(2.0, Double(attempt))
    let jitter = Double.random(in: 0...0.5)
    return base + jitter
}

func sendWithRetry(
    _ request: URLRequest,
    maxAttempts: Int = 3,
    session: URLSession = .shared
) async throws -> (Data, HTTPURLResponse) {
    var req = request
    if req.value(forHTTPHeaderField: "idempotency-key") == nil {
        req.setValue(UUID().uuidString, forHTTPHeaderField: "idempotency-key")
    }

    var lastTransportError: Error?

    for attempt in 0..<maxAttempts {
        let isLastAttempt = attempt == maxAttempts - 1

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ProxyError.serverError(0)
            }

            switch http.statusCode {
            case 200...299:
                return (data, http)
            case 401:
                throw ProxyError.authError
            case 402:
                throw ProxyError.insufficientBalance
            case 413:
                throw ProxyError.payloadTooLarge
            case 429:
                if isLastAttempt { throw ProxyError.rateLimited }
                let wait = retryAfterSeconds(from: http) ?? exponentialDelay(attempt: attempt)
                try await Task.sleep(for: .seconds(wait))
                continue
            case 500...599:
                if isLastAttempt { throw ProxyError.serverError(http.statusCode) }
                let wait = retryAfterSeconds(from: http) ?? exponentialDelay(attempt: attempt)
                try await Task.sleep(for: .seconds(wait))
                continue
            default:
                throw ProxyError.clientError(http.statusCode)
            }
        } catch let error as ProxyError {
            throw error
        } catch {
            lastTransportError = error
            if isLastAttempt { throw error }
            try await Task.sleep(for: .seconds(exponentialDelay(attempt: attempt)))
            continue
        }
    }

    throw lastTransportError ?? ProxyError.serverError(0)
}
