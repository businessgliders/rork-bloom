import Foundation

/// Bundled, offline weekly content (weeks 1–42).
nonisolated struct WeekContent: Codable, Identifiable {
    let week: Int
    let emoji: String
    let size: String
    let lengthCm: Double?
    let weightG: Double?
    let baby: String
    let mom: String
    let partner: String

    var id: Int { week }

    func babyText(name: String) -> String { baby.replacingOccurrences(of: "{baby}", with: name) }
    func momText(name: String) -> String { mom.replacingOccurrences(of: "{mom}", with: name) }
    func partnerText(mom: String, baby: String) -> String {
        partner.replacingOccurrences(of: "{mom}", with: mom).replacingOccurrences(of: "{baby}", with: baby)
    }

    var measurementText: String? {
        var parts: [String] = []
        if let lengthCm {
            parts.append(lengthCm < 1 ? "\(Int((lengthCm * 10).rounded())) mm" : "\(lengthCm.formatted(.number.precision(.fractionLength(0...1)))) cm")
        }
        if let weightG {
            if weightG >= 1000 {
                parts.append("\((weightG / 1000).formatted(.number.precision(.fractionLength(1)))) kg")
            } else if weightG >= 1 {
                parts.append("\(Int(weightG)) g")
            } else {
                parts.append("under 1 g")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var sizeSentence: String {
        week <= 2 ? "Not here yet: \(size)" : "about the size of \(size)"
    }
}

nonisolated enum WeekLibrary {
    static let all: [WeekContent] = {
        guard let url = Bundle.main.url(forResource: "weeks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let weeks = try? JSONDecoder().decode([WeekContent].self, from: data) else {
            return []
        }
        return weeks.sorted { $0.week < $1.week }
    }()

    static func week(_ n: Int) -> WeekContent? {
        let clamped = min(max(n, 1), 42)
        return all.first { $0.week == clamped }
    }
}
