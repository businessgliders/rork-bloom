import SwiftUI
import UIKit

/// The mark drawing itself, the dot popping in and the wordmark rising beside it.
/// Shared by the cold-launch splash and the welcome screen.
struct CarryLockupIntro: View {
    var markSize: CGFloat = 72
    var wordSize: CGFloat = 46
    /// 0 idle, 1 arc drawn, 2 dot in, 3 wordmark in.
    var stage: Int
    var dotPulse = false
    /// Fades the wordmark out while the mark keeps going (the zoom).
    var wordHidden = false

    var body: some View {
        HStack(spacing: markSize * 0.22) {
            CarryMark(
                size: markSize,
                progress: stage >= 1 ? 1 : 0,
                dotScale: stage >= 2 ? (dotPulse ? 1.22 : 1) : 0
            )
            CarryWordmark(size: wordSize)
                .opacity(stage >= 3 && !wordHidden ? 1 : 0)
                .offset(y: stage >= 3 ? 0 : 8)
        }
    }
}

/// Every cold launch, once onboarded: the lockup intro (about 1.4 s). Signed-in people
/// then see "Welcome back, name", the dot pulses and the mark zooms through to home.
struct LaunchSplash: View {
    var greetingName: String?
    /// Called when the zoom starts, so home can scale in behind it.
    var onReveal: () -> Void
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 0
    @State private var greeting = false
    @State private var pulse = false
    @State private var zoom = false
    @State private var fade = false

    var body: some View {
        ZStack {
            Theme.dayCanvas
                .ignoresSafeArea()
                .opacity(zoom || fade ? 0 : 1)

            VStack(spacing: 14) {
                // The mark zooms towards the camera (anchored on the mark) and fades.
                CarryLockupIntro(stage: stage, dotPulse: pulse, wordHidden: zoom)
                    .scaleEffect(zoom ? 12 : 1, anchor: UnitPoint(x: 0.18, y: 0.5))
                    .opacity(zoom ? 0 : 1)

                if let greetingName {
                    Text("Welcome back, \(greetingName)")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.daySecondary)
                        .opacity(greeting && !zoom ? 1 : 0)
                        .offset(y: greeting ? 0 : 6)
                }
            }
            .opacity(fade ? 0 : 1)
        }
        .allowsHitTesting(!zoom && !fade)
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { stage = 3; greeting = true }
            try? await Task.sleep(for: .seconds(0.9))
            onReveal()
            withAnimation(.easeInOut(duration: 0.35)) { fade = true }
            try? await Task.sleep(for: .seconds(0.4))
            onFinish()
            return
        }
        withAnimation(.easeOut(duration: 0.7)) { stage = 1 }
        try? await Task.sleep(for: .seconds(0.55))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { stage = 2 }
        try? await Task.sleep(for: .seconds(0.2))
        withAnimation(.easeOut(duration: 0.4)) { stage = 3 }
        if greetingName != nil {
            try? await Task.sleep(for: .seconds(0.2))
            withAnimation(.easeOut(duration: 0.35)) { greeting = true }
            try? await Task.sleep(for: .seconds(0.25))
            withAnimation(.easeInOut(duration: 0.18)) { pulse = true }
            try? await Task.sleep(for: .seconds(0.18))
            withAnimation(.easeInOut(duration: 0.22)) { pulse = false }
            try? await Task.sleep(for: .seconds(0.2))
        } else {
            try? await Task.sleep(for: .seconds(0.45))
        }
        onReveal()
        withAnimation(.easeIn(duration: 0.5)) { zoom = true }
        try? await Task.sleep(for: .seconds(0.5))
        onFinish()
    }
}
