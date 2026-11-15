import SwiftUI

/// Every medication, current and stopped. Tap one to edit it.
struct ManageMedsView: View {
    var onEdit: (Medication) -> Void
    var onAdd: () -> Void

    @Environment(AppStore.self) private var store

    var body: some View {
        let today = PregnancyMath.calendar.startOfDay(for: store.now)
        let meds = store.sortedMedications
        let current = meds.filter { ($0.endDate ?? .distantFuture) >= today }
        let stopped = meds.filter { ($0.endDate ?? .distantFuture) < today }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if meds.isEmpty {
                    Text("No medications yet.")
                        .font(.bloom(.body))
                        .foregroundStyle(Theme.textSecondary)
                        .bloomCard()
                }
                if !current.isEmpty { group(title: "Taking now", meds: current, faded: false) }
                if !stopped.isEmpty { group(title: "Stopped", meds: stopped, faded: true) }

                Button(action: onAdd) {
                    Label("Add medication", systemImage: "plus")
                }
                .buttonStyle(BloomPrimaryButtonStyle())
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(BloomBackground())
        .navigationTitle("Medications")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func group(title: String, meds: [Medication], faded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.bloom(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
            ForEach(meds) { med in
                Button { onEdit(med) } label: { row(med, faded: faded) }
                    .buttonStyle(PressableStyle())
            }
        }
    }

    private func timesLine(_ med: Medication) -> String {
        if med.managed {
            let times = med.plannedTimes(on: store.now).sorted()
            return times.isEmpty ? "In your routine" : "Today " + times.map { $0.date(on: .now).formatted(date: .omitted, time: .shortened) }.joined(separator: ", ")
        }
        return "\(med.schedule.summary) · \(med.times.sorted().map { $0.date(on: .now).formatted(date: .omitted, time: .shortened) }.joined(separator: ", "))"
    }

    private func row(_ med: Medication, faded: Bool) -> some View {
        HStack(spacing: 14) {
            MedBadge(medication: med, size: 52, fill: faded ? Theme.surfaceMuted : Theme.blushSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text(med.displayTitle)
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                Text(timesLine(med))
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                Text(faded ? "Stopped \(med.endDate?.formatted(date: .abbreviated, time: .omitted) ?? "")" : med.foodSummary)
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(med.foodRule == .emptyStomach && !faded ? Theme.coralDeep : Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .bloomCard(padding: 16)
        .opacity(faded ? 0.75 : 1)
    }
}
