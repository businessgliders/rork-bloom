import SwiftUI

struct WeekDetailSheet: View {
    @State var week: Int
    var profile: PregnancyProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let content = WeekLibrary.week(week) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("What happens at week \(content.week)")
                            .font(.bloom(.largeTitle, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())

                        HStack(spacing: 18) {
                            ZStack {
                                BlobShape(seed: content.week)
                                    .fill(Theme.peachSoft)
                                Text(content.emoji)
                                    .font(.system(size: 70))
                            }
                            .frame(width: 140, height: 130)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(content.week <= 2 ? content.size.capitalizedFirst : "Size of \(content.size)")
                                    .font(.bloom(.title3, weight: .bold))
                                    .foregroundStyle(Theme.text)
                                if let length = content.lengthCm, content.week >= 3 {
                                    stat("Length", value: length < 1 ? "\(Int((length * 10).rounded())) mm" : "\(length.formatted(.number.precision(.fractionLength(0...1)))) cm")
                                }
                                if let weight = content.weightG, content.week >= 4 {
                                    stat("Weight", value: weight >= 1000 ? "\((weight / 1000).formatted(.number.precision(.fractionLength(1)))) kg" : (weight < 1 ? "under 1 g" : "\(Int(weight)) g"))
                                }
                            }
                        }

                        section(symbol: "shoeprints.fill", tint: Theme.sage, title: "\(profile.babyName) this week",
                                text: content.babyText(name: profile.babyName))
                        section(symbol: "person.fill", tint: Theme.blush, title: "How \(profile.momName) may feel",
                                text: content.momText(name: profile.momName))
                        section(symbol: "person.2.fill", tint: Theme.peach,
                                title: profile.hasPartner ? "A tip for \(profile.partnerName)" : "A tip for your partner",
                                text: content.partnerText(mom: profile.momName, baby: profile.babyName))

                        Text("All measurements are approximate and vary within the normal range. General information, not medical advice.")
                            .font(.bloom(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(22)
                    .animation(.snappy, value: week)
                }
            }
            .background(CarryBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { change(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(week <= 1)
                        .accessibilityLabel("Previous week")
                    Button { change(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(week >= 42)
                        .accessibilityLabel("Next week")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func change(_ delta: Int) {
        Haptics.select()
        withAnimation(.snappy) { week = min(max(week + delta, 1), 42) }
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.bloom(.caption, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.bloom(.headline, weight: .bold))
                .foregroundStyle(Theme.text)
        }
    }

    private func section(symbol: String, tint: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: .circle)
                Text(title)
                    .font(.bloom(.title3, weight: .heavy))
                    .foregroundStyle(Theme.text)
            }
            Text(text)
                .font(.bloom(.body))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .bloomCard(padding: 18)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
