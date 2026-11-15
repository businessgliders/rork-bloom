import SwiftUI
import UIKit

/// Lets SwiftUI insert a picked name where she is typing, and close the keyboard.
@MainActor
final class MedsEditorController {
    fileprivate weak var textView: UITextView?
    /// The word being typed (with its "@", if any), replaced by a picked name.
    fileprivate var wordRange: NSRange?

    func insert(_ name: String) {
        guard let tv = textView, let range = wordRange,
              let ns = tv.text as NSString?, NSMaxRange(range) <= ns.length else { return }
        let after = NSMaxRange(range) < ns.length ? ns.substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        let insertion = name + (after == " " ? "" : " ")
        guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let textRange = tv.textRange(from: start, to: end) else { return }
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
        tv.replace(textRange, withText: insertion)
        wordRange = nil
        if after == " ", let next = tv.position(from: tv.selectedTextRange?.end ?? end, offset: 1) {
            tv.selectedTextRange = tv.textRange(from: next, to: next)
        }
        tv.delegate?.textViewDidChange?(tv)
    }

    func dismiss() { textView?.resignFirstResponder() }

    /// The line holding the caret while she is typing, or nil when the editor is not focused.
    var caretLine: String? {
        guard let tv = textView, tv.isFirstResponder else { return nil }
        let ns = (tv.text ?? "") as NSString
        let loc = min(tv.selectedRange.location, ns.length)
        return ns.substring(with: ns.lineRange(for: NSRange(location: loc, length: 0)))
            .trimmingCharacters(in: .newlines)
    }
}

/// What she is typing at the caret: an "@" mention (query may be empty) or a word of 2+ letters.
struct EditorQuery: Equatable {
    var word: String
    var isMention: Bool
}

/// "Your meds & rules": a plain-text editor where known medication names show as subtle tinted tokens.
/// Saved exactly as typed; grows with its text (the screen scrolls).
struct MedsTextEditor: UIViewRepresentable {
    @Binding var text: String
    var names: [String]
    var placeholder: String
    var controller: MedsEditorController
    var onQuery: (EditorQuery?) -> Void
    var onFocus: (Bool) -> Void
    /// Vertical centre of each line (by "\n" line index), in the editor's coordinates.
    var onLineCenters: ([CGFloat]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorTextView {
        let tv = EditorTextView()
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 18, right: 40)
        tv.font = Coordinator.font
        tv.adjustsFontForContentSizeCategory = true
        tv.autocapitalizationType = .sentences
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        // Autocorrect rewrites med names and half-typed names ("pr" → "or") the moment focus moves to a suggestion.
        tv.autocorrectionType = .no
        tv.spellCheckingType = .yes
        tv.accessibilityIdentifier = "meds-text-editor"
        tv.accessibilityLabel = "Your meds and rules"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.onLayout = { [weak coordinator = context.coordinator] in coordinator?.reportLines() }
        tv.placeholderLabel.text = placeholder
        controller.textView = tv
        context.coordinator.textView = tv
        tv.text = text
        context.coordinator.restyle()
        return tv
    }

    func updateUIView(_ tv: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        let namesChanged = coordinator.parent.names != names
        coordinator.parent = self
        controller.textView = tv
        tv.placeholderLabel.text = placeholder
        if tv.text != text {
            tv.text = text
            coordinator.restyle()
        } else if namesChanged {
            coordinator.restyle()
        }
        tv.placeholderLabel.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 340
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, 240))
    }

    final class EditorTextView: UITextView {
        var onLayout: (() -> Void)?
        let placeholderLabel = UILabel()

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholderLabel.numberOfLines = 0
            placeholderLabel.font = Coordinator.font
            placeholderLabel.adjustsFontForContentSizeCategory = true
            placeholderLabel.textColor = UIColor(Theme.textSecondary)
            placeholderLabel.isAccessibilityElement = false
            addSubview(placeholderLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = textContainerInset
            let pad = textContainer.lineFragmentPadding
            let width = bounds.width - inset.left - inset.right - pad * 2
            let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            placeholderLabel.frame = CGRect(x: inset.left + pad, y: inset.top, width: width, height: size.height)
            onLayout?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MedsTextEditor
        weak var textView: UITextView?
        private var lastCenters: [CGFloat] = []
        private var lastQuery: EditorQuery?

        static var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

        init(_ parent: MedsTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if textView.markedTextRange == nil { restyle() }
            if parent.text != textView.text { parent.text = textView.text }
            (textView as? EditorTextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
            updateQuery()
            reportLines()
            revealCaret()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateQuery()
            revealCaret()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus(true)
            updateQuery()
            // Once the keyboard and the suggestion bar are up.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                self.revealCaret()
            }
        }

        /// The editor grows instead of scrolling, so the screen's scroll view keeps the caret above the
        /// keyboard and the suggestion bar.
        func revealCaret() {
            Task { @MainActor [weak self] in
                guard let tv = self?.textView, tv.isFirstResponder, let end = tv.selectedTextRange?.end else { return }
                var view = tv.superview
                while let v = view, !(v is UIScrollView) || (v as? UIScrollView)?.isScrollEnabled == false { view = v.superview }
                guard let scroll = view as? UIScrollView else { return }
                let caret = tv.convert(tv.caretRect(for: end), to: scroll).insetBy(dx: 0, dy: -28)
                scroll.scrollRectToVisible(caret, animated: true)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocus(false)
            // Keep the word's range: a suggestion tap can land just as focus leaves.
            let range = parent.controller.wordRange
            setQuery(nil, range: range)
        }

        /// Known names (whole words, any case) get a soft rose tint; everything else is plain text.
        func restyle() {
            guard let tv = textView else { return }
            let selected = tv.selectedRange
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 8
            let base: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: UIColor(Theme.text),
                .paragraphStyle: paragraph,
            ]
            let styled = NSMutableAttributedString(string: tv.text ?? "", attributes: base)
            let full = NSRange(location: 0, length: styled.length)
            let tokenFont = UIFont.systemFont(ofSize: Self.font.pointSize, weight: .semibold)
            var taken = IndexSet()
            for name in parent.names.sorted(by: { $0.count > $1.count }) where name.count >= 2 {
                let pattern = "(?<![\\p{L}\\p{N}])@?" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: styled.string, range: full) {
                    let r = match.range
                    guard !taken.intersects(integersIn: r.location..<NSMaxRange(r)) else { continue }
                    taken.insert(integersIn: r.location..<NSMaxRange(r))
                    styled.addAttributes([
                        .backgroundColor: UIColor(Theme.blushSoft),
                        .foregroundColor: UIColor(Theme.blushDeep),
                        .font: tokenFont,
                    ], range: r)
                }
            }
            tv.attributedText = styled
            tv.typingAttributes = base
            if NSMaxRange(selected) <= styled.length { tv.selectedRange = selected }
        }

        private func updateQuery() {
            guard let tv = textView, tv.isFirstResponder, tv.selectedRange.length == 0 else {
                setQuery(nil, range: nil)
                return
            }
            let ns = (tv.text ?? "") as NSString
            var start = tv.selectedRange.location
            func isWordChar(_ c: unichar) -> Bool {
                guard let scalar = UnicodeScalar(c) else { return false }
                return CharacterSet.alphanumerics.contains(scalar) || c == 45 // "-"
            }
            while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
            let word = ns.substring(with: NSRange(location: start, length: tv.selectedRange.location - start))
            if start > 0, ns.character(at: start - 1) == 64 { // "@"
                setQuery(EditorQuery(word: word, isMention: true),
                         range: NSRange(location: start - 1, length: word.utf16.count + 1))
            } else if word.count >= 2 {
                setQuery(EditorQuery(word: word, isMention: false), range: NSRange(location: start, length: word.utf16.count))
            } else {
                setQuery(nil, range: nil)
            }
        }

        private func setQuery(_ query: EditorQuery?, range: NSRange?) {
            parent.controller.wordRange = range
            guard query != lastQuery else { return }
            lastQuery = query
            let callback = parent.onQuery
            Task { @MainActor in callback(query) }
        }

        /// Where each line sits, so the screen can shimmer next to the lines being read.
        func reportLines() {
            guard let tv = textView else { return }
            let ns = (tv.text ?? "") as NSString
            var centers: [CGFloat] = []
            var offset = 0
            for line in (tv.text ?? "").components(separatedBy: "\n") {
                if let pos = tv.position(from: tv.beginningOfDocument, offset: min(offset, ns.length)) {
                    centers.append(tv.caretRect(for: pos).midY.rounded())
                } else {
                    centers.append(0)
                }
                offset += line.utf16.count + 1
            }
            guard centers != lastCenters else { return }
            lastCenters = centers
            let callback = parent.onLineCenters
            Task { @MainActor in callback(centers) }
        }
    }
}

/// Names that fit what she is typing: a prefix of any word in the name, never the exact word already typed.
enum NameSuggestions {
    static func matches(_ query: EditorQuery, in names: [String], limit: Int = 6) -> [String] {
        let q = query.word.lowercased()
        let hits = names.filter { name in
            let lower = name.lowercased()
            if !query.isMention && lower == q { return false }
            if q.isEmpty { return query.isMention }
            let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return lower.hasPrefix(q) || words.contains { $0.hasPrefix(q) }
        }
        return Array(hits.prefix(limit))
    }
}

extension MedsEditorController {
    /// "Pick a med": types an "@" so the full list shows.
    func insertMarker() {
        guard let tv = textView else { return }
        let ns = (tv.text ?? "") as NSString
        let loc = tv.selectedRange.location
        let needsSpace = loc > 0 && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: loc - 1)) ?? " ")
        tv.insertText(needsSpace ? " @" : "@")
    }
}

