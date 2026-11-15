import SwiftUI

struct WeekDetailSheet: View {
    @State var week: Int
    var profile: PregnancyProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let content = WeekLibrary.week(week) {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(content.sizeLabel)
                                .font(.bloom(.title3, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Approximate size this week")
                                .font(.bloom(.subheadline))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                        if let length = content.lengthCm, content.week >= 3 {
                            LabeledContent("Length", value: length < 1 ? "\(Int((length * 10).rounded())) mm" : "\(length.formatted(.number.precision(.fractionLength(0...1)))) cm")
                        }
                        if let weight = content.weightG, content.week >= 4 {
                            LabeledContent("Weight", value: weight >= 1000 ? "\((weight / 1000).formatted(.number.precision(.fractionLength(1)))) kg" : (weight < 1 ? "under 1 g" : "\(Int(weight)) g"))
                        }
                    }

                    section(title: "\(profile.babyName) this week", text: content.babyText(name: profile.babyName))
                    section(title: "How \(profile.momName) may feel", text: content.momText(name: profile.momName))
                    section(title: profile.hasPartner ? "A tip for \(profile.partnerName)" : "A tip for your partner",
                            text: content.partnerText(mom: profile.momName, baby: profile.babyName))

                    Section {
                    } footer: {
                        Text("All measurements are approximate and vary within the normal range. General information, not medical advice.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Week \(week)")
            .navigationBarTitleDisplayMode(.large)
            .contentTransition(.numericText())
            .animation(.snappy, value: week)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .tint(Theme.blushDeep)
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
            .tint(Theme.blushDeep)
        }
        .presentationDragIndicator(.visible)
    }

    private func change(_ delta: Int) {
        Haptics.select()
        withAnimation(.snappy) { week = min(max(week + delta, 1), 42) }
    }

    private func section(title: String, text: String) -> some View {
        Section(title) {
            Text(text)
                .font(.bloom(.body))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
