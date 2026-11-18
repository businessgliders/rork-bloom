import SwiftUI

/// The centred card right after a dose that starts a no-food window is logged (or the
/// "No food until" notification is tapped). A live countdown ring follows taken_at; it closes
/// itself when the window ends. Styled like the Move popup.
struct NoFoodCountdownCard: View {
    var alert: NoFoodAlert
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var permission = NotificationPermission.shared

    private static let ringSize: CGFloat = 190
    private static let ringWidth: CGFloat = 14

    var body: some View {
        VStack(spacing: 18) {
            pill
            title
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ring(now: context.date)
            }
            VStack(spacing: 6) {
                Text(alert.note ?? "Avoid food until then.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.dayText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if permission.isOn {
                    Text("We'll let you know when you can eat.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.daySecondary)
                        .multilineTextAlignment(.center)
                }
            }
            Button {
                Haptics.select()
                onClose()
            } label: {
                Text("Got it").frame(maxWidth: .infinity)
            }
            .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.rose))
            .accessibilityIdentifier("nofood-card-done")
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(Theme.dayCard, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .padding(.horizontal, 20)
        .scaleEffect(shown || reduceMotion ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .onAppear {
            Haptics.warning()
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
        .task(id: alert.id) {
            // Closes on its own when the window is over.
            let wait = alert.end.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { onClose() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("nofood-card")
    }

    // MARK: Parts

    private var pill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text("\(alert.namesText) taken \u{00B7} \(alert.lastTakenAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Theme.greenText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.greenText.opacity(0.1), in: .capsule)
    }

    private var title: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.terraDot).frame(width: 9, height: 9)
            Text("No food until \(alert.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.dayText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func ring(now: Date) -> some View {
        let total = max(alert.end.timeIntervalSince(alert.start), 1)
        let left = max(alert.end.timeIntervalSince(now), 0)
        let fraction = min(left / total, 1)
        return ZStack {
            Circle()
                .stroke(Theme.terraTint, lineWidth: Self.ringWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.terraDot, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
            VStack(spacing: 0) {
                Text(Self.countdown(left))
                    .font(.system(size: 44, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.terraText)
                    .contentTransition(.numericText(countsDown: true))
                Text("left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.daySecondary)
            }
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Medication.durationText(max(1, Int((left / 60).rounded(.up))))) left")
        .accessibilityIdentifier("nofood-countdown")
    }

    /// "29:58", or "1:05:00" for an hour or more.
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
