import SwiftUI

/// After a dose taken well off its planned time: the rest of today, recalculated from the real time.
/// "Just today" keeps the routine; "Update my … routine" moves its times for good.
struct OffScheduleSheet: View {
    var proposal: RescheduleProposal

    @Environment(AppStore.self) private var store

    private var isViewer: Bool { !store.isShared || proposal.owner == store.viewerRole }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(proposal.takenName) taken at \(proposal.takenAt.formatted(date: .omitted, time: .shortened))")
                            .font(.bloom(.title3, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(proposal.violations.isEmpty
                             ? "The rest of today moves so every rule still holds."
                             : "The rest of today moves to the earliest times that fit.")
                            .font(.bloom(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(proposal.changes.enumerated()), id: \.element.id) { index, change in
                            if index > 0 { Divider().padding(.leading, 16) }
                            HStack(spacing: 10) {
                                Text(change.name)
                                    .font(.bloom(.body, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Spacer(minLength: 8)
                                Text(ScheduleEngine.clock(change.from.minutesFromMidnight))
                                    .strikethrough(color: Theme.textSecondary)
                                    .foregroundStyle(Theme.textSecondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(ScheduleEngine.clock(change.to.minutesFromMidnight))
                                    .foregroundStyle(Theme.blushDeep)
                            }
                            .font(.bloom(.subheadline, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))

                    ForEach(proposal.violations) { ViolationCard(violation: $0) }

                    VStack(spacing: 10) {
                        Button {
                            Haptics.success()
                            store.applyReschedule(proposal, updateTemplate: false)
                        } label: {
                            Text("Just today").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BloomPrimaryButtonStyle())
                        .accessibilityIdentifier("reschedule-today")

                        Button {
                            Haptics.success()
                            store.applyReschedule(proposal, updateTemplate: true)
                        } label: {
                            Text("Update \(isViewer ? "my" : "\(store.name(for: proposal.owner))'s") \(proposal.templateLabel) routine")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BloomSoftButtonStyle())
                        .accessibilityIdentifier("reschedule-template")

                        Button("Keep the plan") {
                            Haptics.tap()
                            store.reschedule = nil
                        }
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("reschedule-keep")
                    }
                }
                .padding(22)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Later today")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(32)
    }
}
