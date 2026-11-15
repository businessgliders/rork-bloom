import SwiftUI

/// Horizontal strip of days (a week back, a week ahead) with tiny progress rings.
struct DayPicker: View {
    @Binding var selection: Date
    var today: Date
    /// Returns (logged, total) for a day.
    var progress: (Date) -> (Int, Int)

    private var days: [Date] {
        (-6...6).map { PregnancyMath.addDays($0, to: today) }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        dayCell(day)
                            .id(day)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .onAppear { reader.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, newValue in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    reader.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = PregnancyMath.calendar
        let isSelected = cal.isDate(day, inSameDayAs: selection)
        let isToday = cal.isDate(day, inSameDayAs: today)
        let (logged, total) = progress(day)
        let isFuture = day > today

        return Button {
            Haptics.select()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { selection = day }
        } label: {
            VStack(spacing: 6) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.bloom(.caption2, weight: .bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ZStack {
                    ProgressRing(
                        progress: total == 0 ? 0 : Double(logged) / Double(total),
                        lineWidth: 4,
                        tint: isSelected ? .white : Theme.sage,
                        track: isSelected ? .white.opacity(0.3) : Theme.ringTrack
                    )
                    .opacity(total == 0 || isFuture ? 0.35 : 1)
                    Text(day.formatted(.dateTime.day()))
                        .font(.bloom(.headline, weight: .heavy))
                        .foregroundStyle(isSelected ? .white : Theme.text)
                        .monospacedDigit()
                }
                .frame(width: 40, height: 40)
            }
            .frame(width: 54)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? Theme.blush : (isToday ? Theme.blushSoft : Theme.surface.opacity(0.75)))
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(isToday ? "Today, " : "")\(day.formatted(.dateTime.weekday(.wide).month().day())), \(logged) of \(total) logged")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
