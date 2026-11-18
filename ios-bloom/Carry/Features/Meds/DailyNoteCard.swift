import SwiftUI

/// Board 23: today's note, centred over a dimmed screen. On the first open of the day the title types
/// letter by letter behind a thin rose cursor, the subtitle fades in, then the body types word by word.
/// The full text is laid out from the start and revealed in place, so the card never changes height.
/// A tap on the text skips to the end; "Start my day" works from the first frame.
struct DailyNoteCard: View {
    var presentation: DailyNoteCenter.Presentation
    /// "Week 10, day 2 · about a strawberry"
    var subtitle: String?
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var start: Date?
    @State private var finished = false
    @State private var dotsIn = 0
    @State private var countIn = false
    @State private var dragY: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @State private var finishTask: Task<Void, Never>?

    private var note: DailyNote { presentation.note }
    private var types: Bool { presentation.animate && !reduceMotion }
    private var timing: NoteTiming { NoteTiming(title: note.title, body: note.body) }

    static let gradientTop = Theme.dayCard
    static let gradientBottom = Theme.roseTint

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Group {
                if types && !finished {
                    TimelineView(.animation(minimumInterval: nil, paused: finished)) { context in
                        let t = start.map { context.date.timeIntervalSince($0) } ?? 0
                        textBlock(t: t)
                    }
                } else {
                    textBlock(t: .infinity)
                }
            }
            .contentShape(.rect)
            .onTapGesture { skip() }
            if let recap = note.recap { medsRow(recap) }
            Button {
                Haptics.select()
                onClose()
            } label: {
                Text("Start my day").frame(maxWidth: .infinity)
            }
            .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.rose))
            .accessibilityIdentifier("daily-note-start")
        }
        .padding(22)
        .frame(maxWidth: 380)
        .background(
            LinearGradient(colors: [Self.gradientTop, Self.gradientBottom], startPoint: .top, endPoint: .bottom),
            in: .rect(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .padding(.horizontal, 20)
        .offset(y: max(0, dragY))
        .scaleEffect(shown || reduceMotion ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { dragY = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                    }
                }
        )
        .onAppear(perform: begin)
        .onDisappear { finishTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("daily-note-card")
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 7) {
            CarryMark(size: 16)
            Text("Today's note \u{00B7} \(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.daySecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Title, subtitle and body at time `t` (seconds since the card appeared; infinity = all shown).
    private func textBlock(t: Double) -> some View {
        let tm = timing
        let titleRevealed = tm.titleRevealed(at: t)
        let bodyAlphas = tm.bodyAlphas(at: t)
        let cursor = tm.cursor(at: t)
        return VStack(alignment: .leading, spacing: 8) {
            RevealText(
                text: note.title,
                alphas: tm.titleAlphas(revealed: titleRevealed),
                cursorAfter: cursor.inTitle ? titleRevealed : nil,
                cursorAlpha: cursor.alpha
            )
            .font(.system(size: 28, weight: .regular, design: .serif).italic())
            .foregroundStyle(Theme.dayText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("daily-note-title")

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.terraText)
                    .opacity(tm.subtitleAlpha(at: t))
            }

            ScrollView {
                RevealText(
                    text: note.body,
                    alphas: bodyAlphas,
                    cursorAfter: cursor.inTitle ? nil : tm.bodyRevealedChars(at: t),
                    cursorAlpha: cursor.inTitle ? 0 : cursor.alpha
                )
                .font(.system(size: 16))
                .lineSpacing(8)
                .foregroundStyle(Theme.dayText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                .accessibilityIdentifier("daily-note-body")
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(height: min(max(bodyHeight, 20), 300))
            .padding(.top, 6)
        }
    }

    private func medsRow(_ recap: DailyNoteRecap) -> some View {
        HStack(spacing: 10) {
            Text("Yesterday's meds")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.daySecondary)
            HStack(spacing: 5) {
                ForEach(Array(recap.items.enumerated()), id: \.offset) { index, status in
                    Circle()
                        .fill(Self.color(status))
                        .frame(width: 8, height: 8)
                        .scaleEffect(index < dotsIn ? 1 : 0.01)
                        .opacity(index < dotsIn ? 1 : 0)
                }
            }
            Spacer(minLength: 6)
            Text("\(recap.taken) of \(recap.total)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.dayText)
                .opacity(countIn ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.dayCard.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yesterday's meds: \(recap.taken) of \(recap.total)")
        .accessibilityIdentifier("daily-note-meds")
    }

    static func color(_ status: DailyNoteRecap.Status) -> Color {
        switch status {
        case .onTime, .late, .early: Theme.greenDot
        case .missed: Theme.terraDot
        case .skipped, .other: Theme.neutralDot
        }
    }

    // MARK: Sequence

    private func begin() {
        withAnimation(.easeOut(duration: 0.3)) { shown = true }
        guard types else {
            finished = true
            showRecap(animated: !reduceMotion && presentation.animate)
            return
        }
        start = .now
        let wait = timing.total
        finishTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            finished = true
            showRecap(animated: true)
        }
    }

    private func skip() {
        guard types, !finished else { return }
        finishTask?.cancel()
        finished = true
        showRecap(animated: false)
    }

    /// The dots pop in 60 ms apart, then "N of M" fades in.
    private func showRecap(animated: Bool) {
        let count = note.recap?.items.count ?? 0
        guard animated, count > 0 else {
            dotsIn = count
            withAnimation(.easeOut(duration: 0.2)) { countIn = true }
            return
        }
        Task { @MainActor in
            for i in 1...count {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { dotsIn = i }
                try? await Task.sleep(for: .milliseconds(60))
            }
            withAnimation(.easeOut(duration: 0.25)) { countIn = true }
        }
    }
}

// MARK: - Timing

/// Title: 35 ms a letter. Subtitle fades in. Body: 45 ms a word, each fading in over 120 ms.
struct NoteTiming {
    let titleChars: [Character]
    let bodyChars: [Character]
    /// For each body character (newlines skipped), the index of its word.
    let bodyWordOf: [Int]
    let bodyWords: Int

    static let lead = 0.3
    static let perChar = 0.035
    static let perWord = 0.045
    static let wordFade = 0.12

    init(title: String, body: String) {
        titleChars = Array(title).filter { $0 != "\n" }
        bodyChars = Array(body).filter { $0 != "\n" }
        var map: [Int] = []
        var word = -1
        var inWord = false
        for c in bodyChars {
            if c.isWhitespace {
                inWord = false
                map.append(max(word, 0))
            } else {
                if !inWord { word += 1; inWord = true }
                map.append(word)
            }
        }
        bodyWordOf = map
        bodyWords = word + 1
    }

    var titleEnd: Double { Self.lead + Double(titleChars.count) * Self.perChar }
    var subtitleStart: Double { titleEnd + 0.1 }
    var bodyStart: Double { titleEnd + 0.4 }
    var bodyEnd: Double { bodyStart + Double(max(bodyWords - 1, 0)) * Self.perWord + Self.wordFade }
    var total: Double { bodyEnd + 0.3 }

    func titleRevealed(at t: Double) -> Int {
        guard t.isFinite else { return titleChars.count }
        return min(titleChars.count, max(0, Int(((t - Self.lead) / Self.perChar).rounded(.down)) + 1))
    }

    func titleAlphas(revealed: Int) -> [Double] {
        (0..<titleChars.count).map { $0 < revealed ? 1 : 0 }
    }

    func subtitleAlpha(at t: Double) -> Double {
        guard t.isFinite else { return 1 }
        return min(1, max(0, (t - subtitleStart) / 0.3))
    }

    func bodyAlphas(at t: Double) -> [Double] {
        guard t.isFinite else { return Array(repeating: 1, count: bodyChars.count) }
        return bodyWordOf.map { w in
            min(1, max(0, (t - bodyStart - Double(w) * Self.perWord) / Self.wordFade))
        }
    }

    func bodyRevealedChars(at t: Double) -> Int {
        guard t.isFinite else { return bodyChars.count }
        let shownWords = Int(((t - bodyStart) / Self.perWord).rounded(.down)) + 1
        guard shownWords > 0 else { return 0 }
        // Up to the end of the last started word (not its trailing space).
        var last = 0
        for (i, w) in bodyWordOf.enumerated() where w < shownWords && !bodyChars[i].isWhitespace { last = i + 1 }
        return last
    }

    /// Where the cursor is and how visible: in the title until the body starts, then in the body; blinks, then fades.
    func cursor(at t: Double) -> (inTitle: Bool, alpha: Double) {
        guard t.isFinite else { return (false, 0) }
        let blink = Int((t / 0.45).rounded(.down)) % 2 == 0 ? 1.0 : 0.2
        if t < bodyStart { return (true, t < Self.lead ? 1 : (t < titleEnd ? 1 : blink)) }
        if t < bodyEnd { return (false, 1) }
        return (false, max(0, 1 - (t - bodyEnd) / 0.3) * blink)
    }
}

// MARK: - Reveal text

/// The whole string laid out once; characters drawn at their own opacity, plus an optional thin cursor.
/// iOS 18 draws with a TextRenderer (cursor included); iOS 17 tints the hidden characters clear.
struct RevealText: View {
    var text: String
    var alphas: [Double]
    var cursorAfter: Int?
    var cursorAlpha: Double

    var body: some View {
        if #available(iOS 18.0, *) {
            Text(text)
                .textRenderer(RevealRenderer(alphas: alphas, cursorAfter: cursorAfter, cursorAlpha: cursorAlpha,
                                             cursorColor: Theme.rose))
                .accessibilityLabel(text)
        } else {
            fallback.accessibilityLabel(text)
        }
    }

    /// Same layout every frame: each run of equal opacity is its own segment.
    private var fallback: Text {
        let chars = Array(text)
        var result = Text("")
        var run = ""
        var runAlpha: Double = -1
        var k = 0
        for c in chars {
            let a = c == "\n" ? max(runAlpha, 0) : (k < alphas.count ? alphas[k] : 1)
            if c != "\n" { k += 1 }
            if a != runAlpha, !run.isEmpty {
                result = result + Text(run).foregroundStyle(Theme.dayText.opacity(runAlpha))
                run = ""
            }
            runAlpha = a
            run.append(c)
        }
        if !run.isEmpty { result = result + Text(run).foregroundStyle(Theme.dayText.opacity(runAlpha)) }
        return result
    }
}

@available(iOS 18.0, *)
private struct RevealRenderer: TextRenderer {
    var alphas: [Double]
    var cursorAfter: Int?
    var cursorAlpha: Double
    var cursorColor: Color

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var i = 0
        var cursorRect: CGRect?
        var firstRect: CGRect?
        for line in layout {
            for run in line {
                for slice in run {
                    let a = i < alphas.count ? alphas[i] : 1
                    if a > 0 {
                        var c = ctx
                        c.opacity = a
                        c.draw(slice)
                    }
                    let rect = slice.typographicBounds.rect
                    if firstRect == nil { firstRect = rect }
                    if let n = cursorAfter, i == n - 1 { cursorRect = rect }
                    i += 1
                }
            }
        }
        guard let n = cursorAfter, cursorAlpha > 0 else { return }
        let x: CGFloat
        let base: CGRect
        if n == 0, let firstRect {
            base = firstRect
            x = firstRect.minX
        } else if let cursorRect {
            base = cursorRect
            x = cursorRect.maxX + 1.5
        } else {
            return
        }
        let height = base.height * 0.82
        let bar = CGRect(x: x, y: base.midY - height / 2, width: 2, height: height)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(cursorColor.opacity(cursorAlpha)))
    }
}
