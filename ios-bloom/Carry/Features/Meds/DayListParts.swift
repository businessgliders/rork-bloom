import SwiftUI

// Shared pieces of the day list (boards 1–6): time · dot · name · trailing control.

enum DayList {
    /// Gap between the time column and the dot, on every list.
    static let timeGap: CGFloat = 12
    /// Wide enough for the widest time in her locale at 15 pt tabular digits ("12:00 PM", "23:58"), never shrunk.
    static let timeLabelWidth: CGFloat = {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        let samples = [0, 10 * 60 + 58, 12 * 60, 20 * 60 + 58, 22 * 60 + 58, 23 * 60 + 58, 11 * 60 + 58]
            .map(ScheduleEngine.clock) + ["Now"]
        let widest = samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 62
        return ceil(widest) + 2
    }()
    /// Leading padding + time label + gap.
    static var timeWidth: CGFloat { 16 + timeLabelWidth + timeGap }
    static let rowHeight: CGFloat = 56
    static let side: CGFloat = 20

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// One row: time column, 9 pt dot, name, and a 44×44 trailing slot.
struct DayRow<Trailing: View>: View {
    var time: String
    var dot: Color
    var name: String
    var muted = false
    var timeColor: Color?
    var nameColor: Color?
    var timeAction: (() -> Void)?
    var nameAction: (() -> Void)?
    var identifier: String = ""
    /// A small line under the time ("was 3:00").
    var timeNote: String? = nil
    /// Flip to bounce the dot once (a dose taken or undone).
    var dotBounce = false
    /// A small line under the name ("Eaten 9:40 AM", "Follows dinner").
    var subtitle: String? = nil
    var subtitleColor: Color? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            timeView
            Circle()
                .fill(dot)
                .frame(width: 9, height: 9)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: reduceMotion ? false : dotBounce) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1.7, duration: 0.12)
                        SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                    }
                }
                .padding(.trailing, 12)
                .accessibilityHidden(true)
            nameView
            Spacer(minLength: 8)
            trailing
                .frame(width: 44, height: 44)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: DayList.rowHeight)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var timeView: some View {
        let label = VStack(alignment: .leading, spacing: 1) {
            Text(time)
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(timeColor ?? (muted ? Theme.dayMuted : Theme.daySecondary))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
            if let timeNote {
                Text(timeNote)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.greenText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
            .frame(width: DayList.timeLabelWidth, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .padding(.trailing, DayList.timeGap)
        if let timeAction {
            Button(action: timeAction) { label }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Change \(name) time, \(time)")
                .accessibilityIdentifier("day-time-\(identifier.isEmpty ? name : identifier)")
        } else {
            label
        }
    }

    @ViewBuilder
    private var nameView: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            FittingName(name: name, color: nameColor ?? (muted ? Theme.dayMuted : Theme.dayText))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(subtitleColor ?? Theme.daySecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
            .padding(.vertical, subtitle == nil ? 0 : 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        if let nameAction {
            Button(action: nameAction) { label }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("day-name-\(identifier.isEmpty ? name : identifier)")
        } else {
            label
        }
    }
}

/// The row name at 17 pt, wrapping between words. In a narrow pane (the folded Duo) a long word such as
/// "Progesterone" would split mid-word, so the size steps down just enough for the longest word (13 pt floor).
private struct FittingName: View {
    var name: String
    var color: Color
    @State private var width: CGFloat = 0

    private var size: CGFloat {
        guard width > 0 else { return 17 }
        let longest = name.split(whereSeparator: \.isWhitespace)
            .map { ($0 as Substring).description as NSString }
            .map { $0.size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width }
            .max() ?? 0
        // A few points of slack: the drawn word runs slightly wider than UIKit measures it.
        let room = width - 6
        guard longest > room else { return 17 }
        return max(13, (17 * room / longest).rounded(.down))
    }

    var body: some View {
        Text(name)
            .font(.system(size: size))
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

extension DayRow where Trailing == EmptyView {
    init(time: String, dot: Color, name: String, muted: Bool = false, timeColor: Color? = nil, nameColor: Color? = nil,
         timeAction: (() -> Void)? = nil, nameAction: (() -> Void)? = nil, identifier: String = "", timeNote: String? = nil,
         subtitle: String? = nil, subtitleColor: Color? = nil) {
        self.init(time: time, dot: dot, name: name, muted: muted, timeColor: timeColor, nameColor: nameColor,
                  timeAction: timeAction, nameAction: nameAction, identifier: identifier, timeNote: timeNote,
                  subtitle: subtitle, subtitleColor: subtitleColor) { EmptyView() }
    }
}

/// Empty rose ring, or a filled green check once taken; skipped shows a muted dash.
/// Taking: the circle fills from the centre and the check draws (0.25 s); undo plays it back.
struct CheckCircle: View {
    enum State { case open, taken, skipped }
    var state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let taken = state == .taken
        ZStack {
            Circle()
                .strokeBorder(state == .skipped ? Theme.dayMuted.opacity(0.6) : Theme.rose.opacity(0.75), lineWidth: 1.5)
                .opacity(taken ? 0 : 1)
            Circle()
                .fill(Theme.greenCheck)
                .scaleEffect(taken || reduceMotion ? 1 : 0.15)
                .opacity(taken ? 1 : 0)
            CheckGlyph()
                .trim(from: 0, to: taken ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 8.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.17).delay(taken ? 0.08 : 0), value: state)
            Capsule().fill(Theme.dayMuted).frame(width: 10, height: 2)
                .opacity(state == .skipped ? 1 : 0)
        }
        .frame(width: 26, height: 26)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.2), value: state)
    }
}

private struct CheckGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// The thin rose "Now" line between past and upcoming.
struct NowRule: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .frame(width: DayList.timeLabelWidth, alignment: .leading)
                .padding(.trailing, DayList.timeGap + 1)
            Circle().fill(Theme.rose).frame(width: 7, height: 7)
            Rectangle().fill(Theme.rose).frame(height: 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 18)
        .accessibilityLabel("Now")
    }
}

/// White card, radius 20, 1 pt dividers between rows (inset past the time column).
struct DayCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
    }
}

struct DayDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.dayDivider).frame(height: 1).padding(.leading, inset)
    }
}

/// The row above the week strip: "2-day streak" left, a monotone 14-day bar chart right.
/// Bar height = share taken, a day with a miss at 35%, the last 14 days ending today, today outlined.
/// Opens How it's going, which shows the same chart larger.
struct StreakChart: View {
    var days: Int
    var bars: [StreakBar]
    /// Hold the burst while the celebration screen covers the list.
    var paused = false
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = 0
    @State private var pendingBurst = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(days == 0 ? "No streak yet" : (days == 1 ? "1-day streak" : "\(days)-day streak"))
                    .font(.system(size: 13, weight: days == 0 ? .regular : .semibold))
                    .foregroundStyle(days == 0 ? Theme.daySecondary : Theme.dayText)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(days)))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StreakBars(bars: bars, barWidth: 4, gap: 3, height: 20, burst: burst)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dayMuted)
            }
            .frame(height: 28)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .animation(.snappy, value: days)
        .onChange(of: days) { old, new in
            guard new > old, !reduceMotion else { return }
            if paused { pendingBurst = true } else { fire() }
        }
        .onChange(of: paused) { _, isPaused in
            if !isPaused, pendingBurst { pendingBurst = false; fire() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days == 0 ? "No streak yet" : "\(days)-day streak")
        .accessibilityValue(StreakBars.summary(bars))
        .accessibilityHint("Opens How it's going")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("meds-streak")
    }

    private func fire() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            burst += 1
        }
    }
}

/// The bars themselves, shared by Meds today (small) and How it's going (large).
struct StreakBars: View {
    var bars: [StreakBar]
    var barWidth: CGFloat
    var gap: CGFloat
    var height: CGFloat
    var color: Color = Theme.daySecondary
    var burst = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    var body: some View {
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                column(bar)
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8)
                        .delay(Double(index) * 0.015), value: grown)
            }
        }
        .frame(height: height, alignment: .bottom)
        .overlay(alignment: .bottomLeading) {
            if let i = bars.firstIndex(where: { $0.kind == .today }) {
                DotBurst(trigger: burst, radius: max(12, height * 0.8))
                    .offset(x: CGFloat(i) * (barWidth + gap) + barWidth / 2, y: -height / 2)
            }
        }
        .onAppear { grown = true }
        .onDisappear { grown = false }
    }

    @ViewBuilder
    private func column(_ bar: StreakBar) -> some View {
        let radius = barWidth / 2
        switch bar.kind {
        case .future, .nothingPlanned:
            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(bar.kind == .future ? 0.35 : 0.5))
                .frame(width: barWidth, height: 2)
        case .past, .today:
            let h = max(2, height * bar.share)
            ZStack(alignment: .bottom) {
                if bar.kind == .today {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(color.opacity(0.7), lineWidth: 1)
                        .frame(width: barWidth + 2, height: height)
                }
                RoundedRectangle(cornerRadius: radius)
                    .fill(color.opacity(bar.missed ? 0.35 : 1))
                    .frame(width: barWidth, height: grown ? h : 0)
            }
            .frame(width: barWidth, height: height, alignment: .bottom)
        }
    }

    static func summary(_ bars: [StreakBar]) -> String {
        let past = bars.filter { $0.kind == .past || $0.kind == .today }
        let full = past.filter { $0.share >= 1 }.count
        let missed = past.filter(\.missed).count
        return "\(full) of the last \(past.count) days fully taken, \(missed) with a miss"
    }
}

/// A ring of six small dots that bursts outward once per trigger.
private struct DotBurst: View {
    var trigger: Int
    var radius: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Circle().fill(Theme.greenDot).frame(width: 4, height: 4)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { dot, t in
                        let angle = Double(i) / 6 * 2 * .pi - .pi / 2
                        dot
                            .offset(x: cos(angle) * radius * t, y: sin(angle) * radius * t)
                            .opacity(t == 0 ? 0 : Double(1 - t * t))
                            .scaleEffect(1.2 - t * 0.6)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0.01, duration: 0.01)
                            CubicKeyframe(1, duration: 0.55)
                            LinearKeyframe(0, duration: 0.01)
                        }
                    }
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Weekday letter + date; today in a rose circle; a 6 pt dot under past days.
struct WeekStrip: View {
    @Binding var selection: Date
    var today: Date
    /// true = all logged, false = partly, nil = none.
    var mark: (Date) -> Bool?
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var days: [Date] {
        let cal = PregnancyMath.calendar
        let weekday = cal.component(.weekday, from: today) // 1 = Sun
        let start = PregnancyMath.addDays(-(weekday - 1), to: today)
        return (0..<7).map { PregnancyMath.addDays($0, to: start) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                cell(day).frame(maxWidth: .infinity)
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let cal = PregnancyMath.calendar
        let isToday = cal.isDate(day, inSameDayAs: today)
        let isSelected = cal.isDate(day, inSameDayAs: selection)
        let past = day < today
        let m = past ? mark(day) : nil
        return Button {
            Haptics.select()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selection = day }
        } label: {
            VStack(spacing: 6) {
                Text(String(day.formatted(.dateTime.weekday(.narrow))))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: isToday || isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? .white : Theme.dayText)
                    .frame(width: 36, height: 36)
                    .background {
                        ZStack {
                            if isToday { Circle().fill(Theme.rose) }
                            // One ring that slides between days (it sits unseen on today's fill).
                            if isSelected {
                                Circle().strokeBorder(Theme.rose, lineWidth: 1.5)
                                    .matchedGeometryEffect(id: "week-selection", in: selectionSpace,
                                                           isSource: true)
                                    .transition(reduceMotion ? .opacity : .identity)
                            }
                        }
                    }
                Circle()
                    .fill(m == true ? Theme.greenDot : Theme.neutralDot)
                    .frame(width: 6, height: 6)
                    .opacity(m == nil ? 0 : 1)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(isToday ? "Today, " : "")\(day.formatted(.dateTime.weekday(.wide).month().day()))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Food OK" / "No food" in its tint, plus one "Next: …" line.
struct FoodStatusCard: View {
    var noFood: Bool
    var trailing: String
    var next: String
    /// "42 min", counting down while no food is allowed.
    var countdown: String? = nil
    var remainingMinutes: Int = 0
    /// 0–1 through the no-food window, drawn as a thin line along the bottom edge.
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle().fill(noFood ? Theme.terraDot : Theme.greenDot).frame(width: 9, height: 9)
                    Text(noFood ? (countdown == nil ? "No food" : "No food \(trailing)") : "Food OK")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer(minLength: 8)
                Text(countdown ?? trailing)
                    .font(.system(size: 15, weight: countdown == nil ? .regular : .semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: remainingMinutes)
            }
            .foregroundStyle(noFood ? Theme.terraText : Theme.greenText)
            Text(next)
                .font(.system(size: 15))
                .foregroundStyle(Theme.daySecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noFood ? Theme.terraTint : Theme.greenTint)
        .overlay(alignment: .bottomLeading) {
            if let progress {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Theme.terraDot.opacity(0.8))
                        .frame(width: geo.size.width * min(1, max(0, progress)), height: 2.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .animation(.easeInOut(duration: 0.6), value: progress)
            }
        }
        .clipShape(.rect(cornerRadius: Theme.dayRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meds-status")
    }
}

/// Dark capsule toast with one action ("Undo").
struct DarkToast: View {
    var message: String
    var action: String = "Undo"
    var onAction: () -> Void
    var onExpire: () -> Void
    var seconds: Double = 8

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.dayCanvas)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: onAction)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.toastAccent)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(Theme.dayText, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .frame(maxWidth: 520)
        .task {
            try? await Task.sleep(for: .seconds(seconds))
            onExpire()
        }
    }
}
