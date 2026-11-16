import SwiftUI

/// Meds & routines: a calm, read-only overview.
/// Routine chips and day-anchor time cards on top, then her meds in her own order with their rules
/// as plain text, and one "Edit my meds & rules" button that opens the text editor.
/// First time (no meds yet) it goes straight to the editor.
struct MedsOverviewView: View {
    var owner: MedOwner
    @Environment(AppStore.self) private var store

    @State private var setup: Bool?
    @State private var selectedRoutine: UUID?
    @State private var showEditor = false

    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }
    private var meds: [Medication] { store.currentMedications(for: owner).filter(\.managed) }
    private var routine: ScheduleTemplate? {
        let templates = store.templates(for: owner)
        return templates.first { $0.id == selectedRoutine } ?? store.activeTemplate(for: owner, on: store.now) ?? templates.first
    }

    var body: some View {
        Group {
            if setup == true {
                MedsRoutinesView(owner: owner, onApplied: {
                    withAnimation(.smooth(duration: 0.4)) { setup = false }
                })
            } else if setup == false {
                overview
            } else {
                Color.clear
            }
        }
        .onAppear {
            if setup == nil { setup = !store.currentMedications(for: owner).contains { $0.managed } }
        }
    }

    private var overview: some View {
        AdaptiveColumns {
            PaneScroll(pane: .primary) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
            }
        } secondary: {
            PaneScroll(pane: .secondary, spacing: 14) {
                medsSection
            }
        } compact: {
            PaneScroll(spacing: 18) {
                RoutineHeader(owner: owner, selectedRoutine: $selectedRoutine)
                medsSection
            }
            .background(BloomBackground())
        }
        .navigationTitle(isViewer ? "Meds & routines" : "\(store.name(for: owner))'s meds & routines")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showEditor) {
            MedsRoutinesView(owner: owner, editing: true, onApplied: { showEditor = false })
        }
        .onAppear {
            if selectedRoutine == nil { selectedRoutine = store.activeTemplate(for: owner, on: store.now)?.id }
        }
        .onDisappear {
            if case .routine = store.scheduleChange?.placement { store.scheduleChange = nil }
        }
    }

    // MARK: Meds

    @ViewBuilder
    private var medsSection: some View {
        let groups = store.linkGroups(owner)
        Text("Your meds & rules")
            .font(.bloom(.title3, weight: .bold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        if meds.isEmpty {
            Text("No medications yet.")
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
        }
        ForEach(meds) { med in
            card(med, color: groups[med.id].map { MedsTodayList.linkColors[$0 % MedsTodayList.linkColors.count] })
        }
        Button {
            Haptics.tap()
            showEditor = true
        } label: {
            Label("Edit my meds & rules", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BloomPrimaryButtonStyle())
        .accessibilityIdentifier("edit-meds-rules")
        Text("Change a med or a rule by editing your own words. Bloom re-reads them and places every time again.")
            .font(.bloom(.footnote))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ med: Medication, color: Color?) -> some View {
        let rules = store.ruleLine(for: med.id, owner: owner)
        let link = store.linkText(for: med.id, owner: owner)
        return HStack(alignment: .top, spacing: 12) {
            MedBadge(medication: med, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(med.shortName)
                        .font(.bloom(.headline, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 6)
                    if med.paused {
                        Text("Paused")
                            .font(.bloom(.caption, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    } else if let minutes = time(of: med) {
                        Text(ScheduleEngine.clock(minutes))
                            .font(.bloom(.subheadline, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.blushDeep)
                    }
                }
                Text(rules.isEmpty ? "No rules" : rules)
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link, let color {
                    Label {
                        Text(link).foregroundStyle(Theme.textSecondary)
                    } icon: {
                        Image(systemName: "link").foregroundStyle(color)
                    }
                    .font(.bloom(.caption, weight: .semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bloomCard(fill: Theme.surface.opacity(0.92), padding: 16)
        .overlay(alignment: .leading) {
            if let color {
                Capsule().fill(color).frame(width: 4).padding(.vertical, 18).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview-med-\(med.shortName)")
    }

    private func time(of med: Medication) -> Int? {
        routine?.dose(for: med.id)?.time.minutesFromMidnight
    }
}
