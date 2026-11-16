import SwiftUI

// Shared pieces of the day list (boards 1–6): time · dot · name · trailing control.

enum DayList {
    static let timeWidth: CGFloat = 78
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            timeView
            Circle()
                .fill(dot)
                .frame(width: 9, height: 9)
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
                .minimumScaleFactor(0.75)
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
            .frame(width: DayList.timeWidth - 16, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(.rect)
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
        let label = FittingName(name: name, color: nameColor ?? (muted ? Theme.dayMuted : Theme.dayText))
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
         timeAction: (() -> Void)? = nil, nameAction: (() -> Void)? = nil, identifier: String = "", timeNote: String? = nil) {
        self.init(time: time, dot: dot, name: name, muted: muted, timeColor: timeColor, nameColor: nameColor,
                  timeAction: timeAction, nameAction: nameAction, identifier: identifier, timeNote: timeNote) { EmptyView() }
    }
}

/// Empty rose ring, or a filled green check once taken; skipped shows a muted dash.
struct CheckCircle: View {
    enum State { case open, taken, skipped }
    var state: State

    var body: some View {
        ZStack {
            switch state {
            case .open:
                Circle().strokeBorder(Theme.rose.opacity(0.75), lineWidth: 1.5)
            case .taken:
                Circle().fill(Theme.greenCheck)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .skipped:
                Circle().strokeBorder(Theme.dayMuted.opacity(0.6), lineWidth: 1.5)
                Capsule().fill(Theme.dayMuted).frame(width: 10, height: 2)
            }
        }
        .frame(width: 26, height: 26)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
    }
}

/// The thin rose "Now" line between past and upcoming.
struct NowRule: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .frame(width: DayList.timeWidth - 16, alignment: .leading)
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

/// "9-day streak ›" in green tint.
struct StreakChip: View {
    var days: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(days == 1 ? "1-day streak" : "\(days)-day streak")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.greenText)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.greenTint, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("meds-streak")
    }
}

/// Weekday letter + date; today in a rose circle; a 6 pt dot under past days.
struct WeekStrip: View {
    @Binding var selection: Date
    var today: Date
    /// true = all logged, false = partly, nil = none.
    var mark: (Date) -> Bool?

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
                        if isToday {
                            Circle().fill(Theme.rose)
                        } else if isSelected {
                            Circle().strokeBorder(Theme.rose, lineWidth: 1.5)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle().fill(noFood ? Theme.terraDot : Theme.greenDot).frame(width: 9, height: 9)
                    Text(noFood ? "No food" : "Food OK")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .foregroundStyle(noFood ? Theme.terraText : Theme.greenText)
            Text(next)
                .font(.system(size: 15))
                .foregroundStyle(Theme.daySecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noFood ? Theme.terraTint : Theme.greenTint, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
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
