import Foundation
import UIKit
import Vision

/// Reads text from a label photo on device with Vision. The photo never leaves the phone.
enum LabelOCR {
    enum OCRError: LocalizedError {
        case noText
        var errorDescription: String? { "Couldn't read any text. Try again with the label flat and well lit." }
    }

    /// Recognised lines, top to bottom.
    static func lines(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw OCRError.noText }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    // Vision's origin is bottom-left: sort by descending y, then x.
                    let sorted = observations.sorted {
                        let a = $0.boundingBox, b = $1.boundingBox
                        if abs(a.midY - b.midY) > 0.015 { return a.midY > b.midY }
                        return a.minX < b.minX
                    }
                    let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if lines.isEmpty {
                        continuation.resume(throwing: OCRError.noText)
                    } else {
                        continuation.resume(returning: lines)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Removes personal details from label text before anything is sent: patient name, address,
/// Rx number, pharmacy, doctor, phone numbers, dates, refills and quantities.
nonisolated enum LabelTextFilter {
    struct Result: Equatable {
        var kept: [String]
        var removedCount: Int
        var text: String { kept.joined(separator: "\n") }
    }

    private static let blockedPatterns: [String] = [
        #"\bpatient\b"#, #"\bname\s*:"#, #"\bfor\s*:"#,
        #"\brx\b"#, #"\brx\s*#"#, #"\brx\s*no"#, #"\bscript\b"#, #"\bprescription\s*(no|number|#)"#,
        #"\bpharmac(y|ist)\b"#, #"\bdrug\s*store\b"#, #"\bcvs\b"#, #"\bwalgreens\b"#, #"\brite\s*aid\b"#, #"\bboots\b"#,
        #"\bdr\.?\s"#, #"\bdoctor\b"#, #"\bprescriber\b"#, #"\bprescribed\s+by\b"#, #"\b(md|do|np|pa-c)\b\.?$"#,
        #"\bphone\b"#, #"\btel\b"#, #"\(\d{3}\)\s*\d{3}"#, #"\d{3}[\s.\-]\d{3}[\s.\-]\d{4}"#,
        #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#, #"\b(date|filled|exp|expires|discard|use by|best before)\b"#,
        #"\brefills?\b"#, #"\bqty\b"#, #"\bquantity\b"#, #"\bndc\b"#, #"\blot\b"#,
        #"\b\d+\s+[a-z0-9 .]+\s(st|street|ave|avenue|rd|road|blvd|lane|ln|dr|drive|way|ct|court)\b\.?"#,
        #"\b(suite|ste|apt|unit)\b"#, #"\b[A-Z]{2}\s+\d{5}(-\d{4})?\b"#, #"\b\d{5}(-\d{4})?$"#,
        #"\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b"#,
        #"#\s*\d{4,}"#, #"\b\d{6,}\b"#,
    ]

    private static let regexes: [NSRegularExpression] = blockedPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines])
    }

    /// - Parameter personalNames: names from the profile; any line containing one is removed.
    static func filter(_ lines: [String], personalNames: [String] = []) -> Result {
        let names = personalNames
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 2 }
        var kept: [String] = []
        var removed = 0
        for line in lines {
            let lower = line.lowercased()
            let range = NSRange(line.startIndex..., in: line)
            let blocked = regexes.contains { $0.firstMatch(in: line, range: range) != nil }
                || names.contains { lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil }
            if blocked {
                removed += 1
            } else if !kept.contains(line) {
                kept.append(line)
            }
        }
        return Result(kept: Array(kept.prefix(14)), removedCount: removed)
    }
}
