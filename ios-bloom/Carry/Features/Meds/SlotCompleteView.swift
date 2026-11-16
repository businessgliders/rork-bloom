import SwiftUI

/// Full-screen celebration when a part of the day's doses is complete.
struct SlotCompleteView: View {
    var celebration: SlotCelebration
    var headline: String
    var subtitle: String
    var onDone: () -> Void

    @State private var fill: Double = 0
    @State private var confetti = 0
    @State private var appeared = false

    var body: some View {
        ZStack {
            CarryBackground()
            CenteredScroll {
                VStack(spacing: 22) {
                    Text("\(celebration.slot.title) done!")
                        .font(.bloom(.headline, weight: .bold))
                        .foregroundStyle(Theme.sageDeep)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.sageSoft, in: .capsule)

                    ZStack {
                        BlobShape(seed: 11)
                            .fill(Theme.peachSoft)
                        FlowerIllustration(fill: fill)
                            .padding(30)
                        ShineMarks()
                            .offset(x: 90, y: -100)
                    }
                    .frame(width: 280, height: 280)
                    .scaleEffect(appeared ? 1 : 0.7)

                    VStack(spacing: 8) {
                        Text(headline)
                            .font(.bloom(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center)
                        Text(subtitle)
                            .font(.bloom(.body, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if celebration.streak > 0 {
                        Label("\(celebration.streak)-day gentle streak", systemImage: "leaf.fill")
                            .font(.bloom(.subheadline, weight: .bold))
                            .foregroundStyle(Theme.sageDeep)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.sageSoft, in: .capsule)
                    }

                    Button("Lovely, thanks", action: onDone)
                        .buttonStyle(CarryPrimaryButtonStyle())
                        .padding(.top, 8)
                        .frame(maxWidth: 360)
                }
                .padding(28)
                .frame(maxWidth: 520)
            }
            ConfettiView(trigger: confetti)
        }
        .onAppear {
            Haptics.celebrate()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.2).delay(0.2)) { fill = celebration.progress }
            confetti += 1
        }
    }
}
