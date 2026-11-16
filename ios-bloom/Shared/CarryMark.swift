import SwiftUI

/// The Carry logo drawn in SwiftUI: an open arc (opening to the right, round caps) with a
/// terracotta dot just right of centre. Proportions follow the app icon artwork.
///
/// - `size`: the arc's outer diameter in points.
/// - `progress`: how much of the arc is drawn, 0–1, clockwise from the lower tip.
/// - `dotScale`: 0 hides the dot, 1 is the logo's dot.
/// - `dotOffset`: the dot centre's distance right of the arc centre, as a fraction of `size`.
struct CarryMark: View {
    var size: CGFloat = 120
    var progress: Double = 1
    var dotScale: CGFloat = 1
    var dotOffset: CGFloat = CarryMark.logoDotOffset
    var arcColor: Color = Theme.rose
    var dotColor: Color = Theme.terraDot
    /// Draws the full arc faintly underneath (used when the arc shows progress).
    var trackColor: Color? = nil
    /// A slow 6 s breath on the dot only (1.0–1.015). Off with Reduce Motion.
    var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured from the icon: the stroke is a sixth of the outer diameter, the dot 28%.
    static let strokeRatio: CGFloat = 0.167
    static let dotRatio: CGFloat = 0.28
    static let logoDotOffset: CGFloat = 0.074
    /// Half the opening, in degrees, centred on the right (the icon's tips sit at ±45°).
    static let gapHalfAngle: Double = 45

    private var stroke: CGFloat { size * Self.strokeRatio }

    var body: some View {
        ZStack {
            if let trackColor {
                CarryArc()
                    .stroke(trackColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
            CarryArc()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(arcColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            Circle()
                .fill(dotColor)
                .frame(width: size * Self.dotRatio, height: size * Self.dotRatio)
                .scaleEffect(dotScale)
                .modifier(DotBreath(active: breathing && !reduceMotion))
                .offset(x: size * dotOffset)
        }
        // The path is inset by half the stroke so the whole mark fits in `size`.
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DotBreath: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { dot, out in
                dot.scaleEffect(out ? 1.015 : 1)
            } animation: { _ in .easeInOut(duration: 3) }
        } else {
            content
        }
    }
}

/// Deep links handled by the app (`carry` URL scheme).
enum CarryLink {
    /// Meds today, scrolled to the current or next dose.
    static let meds = URL(string: "carry://meds")!
}

/// The arc's centre line, starting at the lower tip and running clockwise to the upper tip.
struct CarryArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        // In SwiftUI's flipped coordinates `clockwise: false` runs clockwise on screen.
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(CarryMark.gapHalfAngle),
            endAngle: .degrees(360 - CarryMark.gapHalfAngle),
            clockwise: false
        )
        return path
    }
}

/// App-wide loading spinner: a trimmed segment of the Carry arc turning on its own.
struct CarrySpinner: View {
    var size: CGFloat = 28
    var color: Color = Theme.rose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stroke = max(2, size * CarryMark.strokeRatio)
        Group {
            if reduceMotion {
                // A slow fade instead of a spin.
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .phaseAnimator([0.35, 1.0]) { view, opacity in
                        view.opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.8) }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // The segment breathes between a short dash and most of the arc while it turns.
                    let length = 0.25 + 0.45 * (0.5 + 0.5 * sin(t * 2.6))
                    Circle()
                        .trim(from: 0, to: length)
                        .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees((t * 300).truncatingRemainder(dividingBy: 360)))
                }
            }
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Empty states: a small, quiet Carry mark.
struct CarryEmptyMark: View {
    var size: CGFloat = 44

    var body: some View {
        CarryMark(size: size).opacity(0.4)
    }
}
