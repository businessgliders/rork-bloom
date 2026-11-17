import SwiftUI

/// Board 19: the centred Move card on Meds & routines, opened from a row's handle.
/// A large time readout (green when safe, terracotta when not), a ~5 h track with hour ticks, hatched
/// terracotta where a rule breaks, the dashed green safe band and thin markers for nearby rows.
/// The pill handle snaps every 5 min (light haptic; stronger at the band edges).
struct MovePopup: View {
    struct Request: Identifiable, Equatable {
        var id: UUID
        var name: String
        var bands: DropBands
        /// Other rows of the day for the markers: name and minute.
        var markers: [Marker]
        var day: Date
        var owner: MedOwner
        static func == (a: Request, b: Request) -> Bool { a.id == b.id && a.bands == b.bands }
    }

    struct Marker: Hashable {
        var name: String
        var minutes: Int
        var isMeal: Bool
    }

    var request: Request
    var onCancel: () -> Void
    /// The move was saved; the old minute for the "was" note, and the rows that moved along.
    var onMoved: (_ moved: [UUID: Int]) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var minutes: Int = 0
    @State private var scope: ScheduleChange.Scope = .forward
    @State private var confirmAnyway = false
    @State private var shown = false
    @State private var dragStart: Int?

    private static let span = 300
    private var step: Int { ScheduleEngine.step }
    private var bands: DropBands { request.bands }

    private var window: ClosedRange<Int> {
        let lo = min(max(bands.current - Self.span / 2, 0), 1439 - Self.span)
        return lo...(lo + Self.span)
    }

    private var option: MoveOption? { bands.options[minutes] }
    private var isSafe: Bool { option != nil || minutes == bands.current }
    private var changed: Bool { minutes != bands.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            readout
            track
            legend
            alongside
            scopePicker
            buttons
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(Theme.dayCard, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .padding(.horizontal, 20)
        .scaleEffect(shown || reduceMotion ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .onAppear {
            minutes = bands.current
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
        .onChange(of: minutes) { _, _ in confirmAnyway = false }
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("move-popup")
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Theme.rose)
                Text(request.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.dayText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("was \(ScheduleEngine.clock(bands.current))")
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(Theme.daySecondary)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ScheduleEngine.clock(minutes))
                .font(.system(size: 44, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isSafe ? Theme.greenText : Theme.terraText)
                .contentTransition(.numericText(value: Double(minutes)))
                .animation(.snappy(duration: 0.18), value: minutes)
                .accessibilityIdentifier("move-popup-time")
            HStack(spacing: 6) {
                Circle().fill(isSafe ? Theme.greenDot : Theme.terraDot).frame(width: 7, height: 7)
                Text(statusLine)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSafe ? Theme.greenText : Theme.terraText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("move-popup-status")
        }
    }

    private var statusLine: String {
        if isSafe { return "Safe \u{00B7} every rule is met" }
        return reason(at: minutes)
    }

    private func reason(at t: Int) -> String {
        guard let s = store.dayState(request.owner, on: request.day) else { return "Another rule can't be kept" }
        if t < s.range.lowerBound {
            return PregnancyMath.calendar.isDateInToday(request.day) && t >= s.wake ? "Already past" : "Before you wake"
        }
        if t > s.range.upperBound { return "After bedtime" }
        let preview = store.previewDayChange(owner: request.owner, day: request.day, edit: .dose(request.id, t))
        if let mine = preview?.broken[request.id] { return mine }
        if let (id, other) = preview?.broken.first { return "\(store.medicationNames[id] ?? "Medication") \(other)" }
        return "Another rule can't be kept"
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let w0 = window.lowerBound
            let x: (Int) -> CGFloat = { CGFloat($0 - w0) / CGFloat(Self.span) * w }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size: size, x: x) }
                    .frame(height: 96)
                // The pill handle.
                Capsule()
                    .fill(isSafe ? Theme.greenCheck : Theme.terraDot)
                    .frame(width: 16, height: 40)
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(x: min(max(x(minutes), 8), w - 8), y: 48)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: minutes)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = minutes }
                        let raw = Double(w0) + Double(value.location.x / max(w, 1)) * Double(Self.span)
                        set(Int((raw / Double(step)).rounded()) * step)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(height: 96)
        .accessibilityElement()
        .accessibilityLabel("New time")
        .accessibilityValue("\(ScheduleEngine.clock(minutes)), \(statusLine)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(minutes + step)
            case .decrement: set(minutes - step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("move-popup-track")
    }

    private func set(_ m: Int) {
        let clamped = min(max(m, window.lowerBound), min(window.upperBound, 1435))
        guard clamped != minutes else { return }
        let wasSafe = bands.options[minutes] != nil || minutes == bands.current
        minutes = clamped
        let nowSafe = bands.options[clamped] != nil || clamped == bands.current
        if wasSafe != nowSafe { Haptics.tap() } else { Haptics.select() }
    }

    /// Hatched terracotta where a rule breaks, the dashed green safe band, hour ticks and nearby rows.
    private func draw(_ ctx: GraphicsContext, size: CGSize, x: (Int) -> CGFloat) {
        let top: CGFloat = 30, bottom: CGFloat = 66
        let bar = CGRect(x: 0, y: top, width: size.width, height: bottom - top)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 10), with: .color(Theme.creamBox))

        // Unsafe runs.
        var runs: [(Int, Int)] = []
        var t = window.lowerBound
        var start: Int?
        while t <= window.upperBound {
            let bad = bands.options[t] == nil && t != bands.current
            if bad, start == nil { start = t }
            if !bad, let s = start { runs.append((s, t)); start = nil }
            t += step
        }
        if let s = start { runs.append((s, window.upperBound)) }
        for (a, b) in runs {
            let rect = CGRect(x: x(a), y: top, width: max(2, x(b) - x(a)), height: bottom - top)
            var layer = ctx
            layer.clip(to: Path(roundedRect: rect, cornerRadius: 6))
            layer.fill(Path(rect), with: .color(Theme.terraTint))
            var hatch = Path()
            var hx = rect.minX - rect.height
            while hx < rect.maxX {
                hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                hatch.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY))
                hx += 7
            }
            layer.stroke(hatch, with: .color(Theme.terraDot.opacity(0.45)), lineWidth: 1.2)
        }

        // Safe band.
        if let safe = bands.safe {
            let rect = CGRect(x: x(safe.lowerBound), y: top - 4, width: max(6, x(safe.upperBound) - x(safe.lowerBound)),
                              height: bottom - top + 8)
            let path = Path(roundedRect: rect, cornerRadius: 10)
            ctx.fill(path, with: .color(Theme.greenTint.opacity(0.85)))
            ctx.stroke(path, with: .color(Theme.greenDot), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }

        // Hour ticks.
        var hour = (window.lowerBound + 59) / 60 * 60
        while hour <= window.upperBound {
            let hx = x(hour)
            var tick = Path()
            tick.move(to: CGPoint(x: hx, y: bottom + 2))
            tick.addLine(to: CGPoint(x: hx, y: bottom + 8))
            ctx.stroke(tick, with: .color(Theme.dayMuted), lineWidth: 1)
            let label = ScheduleEngine.clock(hour % 1440).replacingOccurrences(of: ":00", with: "")
            ctx.draw(Text(label).font(.system(size: 11)).foregroundStyle(Theme.dayMuted),
                     at: CGPoint(x: min(max(hx, 18), size.width - 18), y: bottom + 18))
            hour += 60
        }

        // Nearby rows.
        let visible = request.markers.filter { window.contains($0.minutes) }
        var lastLabelX: CGFloat = -100
        for marker in visible.sorted(by: { $0.minutes < $1.minutes }) {
            let mx = x(marker.minutes)
            var line = Path()
            line.move(to: CGPoint(x: mx, y: top - 6))
            line.addLine(to: CGPoint(x: mx, y: bottom))
            let color = marker.isMeal ? Theme.greenDot : Theme.daySecondary
            ctx.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 1)
            if mx - lastLabelX > 56 {
                ctx.draw(Text(marker.name).font(.system(size: 11, weight: .medium)).foregroundStyle(color),
                         at: CGPoint(x: min(max(mx, 28), size.width - 28), y: top - 16))
                lastLabelX = mx
            }
        }
    }

    // MARK: Legend, alongside, scope

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if let safe = bands.safe {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.greenDot, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                            .background(Theme.greenTint, in: .rect(cornerRadius: 3))
                            .frame(width: 14, height: 10)
                        Text("Safe \(rangeText(safe))")
                    }
                } else {
                    Text("Nothing else fits on this day")
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.terraTint)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.terraDot.opacity(0.5), lineWidth: 1))
                        .frame(width: 14, height: 10)
                    Text("Breaks a rule")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Theme.daySecondary)
            let rules = store.ruleLine(for: request.id, owner: request.owner)
            if !rules.isEmpty {
                Text(rules)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dayMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "9:30–10:30 PM" when both ends share AM/PM.
    private func rangeText(_ r: ClosedRange<Int>) -> String {
        let a = ScheduleEngine.clock(r.lowerBound), b = ScheduleEngine.clock(r.upperBound)
        for suffix in [" AM", " PM"] where a.hasSuffix(suffix) && b.hasSuffix(suffix) {
            return "\(a.dropLast(suffix.count))\u{2013}\(b)"
        }
        return "\(a)\u{2013}\(b)"
    }

    private var movingAlong: [String] {
        guard changed else { return [] }
        if let option { return option.alongside.map(\.name) }
        let preview = store.previewDayChange(owner: request.owner, day: request.day, edit: .dose(request.id, minutes))
        let names = store.medicationNames
        return (preview?.moved ?? [:]).sorted { $0.value < $1.value }.compactMap { names[$0.key] }
    }

    @ViewBuilder
    private var alongside: some View {
        let list = movingAlong
        if !list.isEmpty {
            Text("\(list.formatted(.list(type: .and))) will move too")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dayText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.creamBox, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("move-popup-alongside")
        }
    }

    private var scopePicker: some View {
        Picker("When", selection: $scope) {
            Text("Every day").tag(ScheduleChange.Scope.forward)
            Text(PregnancyMath.calendar.isDateInToday(request.day) ? "Just today" : "Just \(request.day.formatted(.dateTime.weekday(.wide)))")
                .tag(ScheduleChange.Scope.today)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("move-popup-scope")
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                Haptics.select()
                onCancel()
            }
            .buttonStyle(BloomSoftButtonStyle(tint: Theme.daySecondary, fill: Theme.creamBox))
            .accessibilityIdentifier("move-popup-cancel")
            Spacer(minLength: 0)
            Button {
                commit()
            } label: {
                Text(isSafe ? "Move to \(ScheduleEngine.clock(minutes))" : (confirmAnyway ? "Move anyway" : "Move to \(ScheduleEngine.clock(minutes))"))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(BloomSoftButtonStyle(tint: isSafe ? .white : Theme.terraText,
                                              fill: isSafe ? Theme.rose : Theme.terraTint))
            .disabled(!changed)
            .opacity(changed ? 1 : 0.45)
            .accessibilityIdentifier("move-popup-confirm")
        }
    }

    private func commit() {
        guard changed else { return }
        if !isSafe && !confirmAnyway {
            Haptics.warning()
            withAnimation(.snappy) { confirmAnyway = true }
            return
        }
        let old = store.dayState(request.owner, on: request.day)?.times ?? [:]
        if let option {
            store.applyMove(owner: request.owner, day: request.day, option: option, medicationID: request.id, scope: scope)
            Haptics.success()
        } else {
            guard store.proposeDayChange(owner: request.owner, day: request.day, edit: .dose(request.id, minutes),
                                         placement: .row(request.id)) != nil else { onCancel(); return }
            store.scheduleChange?.kept = true
            store.applyChange(scope)
            Haptics.warning()
        }
        let after = store.dayState(request.owner, on: request.day)?.times ?? [:]
        var moved: [UUID: Int] = [:]
        for (id, m) in after { if let o = old[id], o != m { moved[id] = o } }
        onMoved(moved)
    }
}
