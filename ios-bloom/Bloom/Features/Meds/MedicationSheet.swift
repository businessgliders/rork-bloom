import SwiftUI

/// Board 7: one bottom sheet from any medication name. Rules in plain words, then the few things
/// that are not in her text: the name shown, who takes it, how this phone follows it, pause, remove.
struct MedicationSheet: View {
    var medication: Medication
    /// "Change these rules": open the editor at this medication's line.
    var onChangeRules: (Medication) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var friendly = ""
    @State private var loaded = false
    @State private var confirmRemove = false
    @State private var moving = false

    private var current: Medication { store.medications.first { $0.id == medication.id } ?? medication }
    private var hasPartner: Bool {
        store.isShared || !(store.profile?.partnerName.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    private var times: String {
        let today = PregnancyMath.calendar.startOfDay(for: store.now)
        let list = store.instances(current.owner, on: today).filter { $0.medication.id == current.id }
        if list.isEmpty {
            return current.times.map { DayList.clock($0.date(on: today)) }.joined(separator: " · ")
        }
        return list.map { DayList.clock($0.anchor) }.joined(separator: " · ")
    }

    private var ruleLines: [String] {
        store.ruleLine(for: current.id, owner: current.owner)
            .components(separatedBy: " · ")
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rulesBox
                settingsCard
                removeButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.dayCanvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.dayCanvas)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            friendly = current.friendlyName
        }
        .onDisappear(perform: saveName)
        .confirmationDialog("Remove \(current.shortName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove medication", role: .destructive) {
                Haptics.warning()
                store.removeMedicationFromPlan(current.id)
                dismiss()
            }
        } message: {
            Text("Its lines leave My rules and it stops from today. Doses already logged stay in the record.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.shortName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.dayText)
                .fixedSize(horizontal: false, vertical: true)
            if !times.isEmpty {
                Text(current.paused ? "Paused" : times)
                    .font(.system(size: 17))
                    .monospacedDigit()
                    .foregroundStyle(current.paused ? Theme.dayMuted : Theme.rose)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rulesBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if ruleLines.isEmpty {
                    Text("No rules yet. Carry places it around your day.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.daySecondary)
                }
                ForEach(ruleLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.dayText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                Haptics.tap()
                let med = current
                dismiss()
                onChangeRules(med)
            } label: {
                Text("Change these rules")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.rose)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("med-sheet-change-rules")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.creamBox, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var settingsCard: some View {
        DayCard {
            settingRow("Name shown") {
                TextField(current.name, text: $friendly)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.dayText)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .accessibilityIdentifier("med-sheet-friendly")
            }
            if hasPartner {
                DayDivider()
                settingRow("Taken by") {
                    Menu {
                        ForEach(MedOwner.allCases) { role in
                            Button {
                                takenBy(role)
                            } label: {
                                if role == current.owner {
                                    Label(store.pickerLabel(for: role), systemImage: "checkmark")
                                } else {
                                    Text(store.pickerLabel(for: role))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if moving { CarrySpinner(size: 16) }
                            Text(store.pickerLabel(for: current.owner))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.daySecondary)
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("med-sheet-taken-by")
                }
            }
            if store.isShared {
                DayDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("On my phone")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.dayText)
                    Picker("On my phone", selection: Binding(
                        get: { store.followMode(for: current) },
                        set: { mode in
                            Haptics.select()
                            store.upsertMedication(current, followMode: mode)
                        }
                    )) {
                        ForEach(FollowMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("med-sheet-follow")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            DayDivider()
            Button {
                Haptics.tap()
                if current.paused { store.resumeMedication(current) } else { store.stopMedication(current) }
            } label: {
                HStack(spacing: 12) {
                    Text("Pause this medication")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.dayText)
                    Spacer(minLength: 8)
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(current.paused ? Color.clear : Theme.dayMuted.opacity(0.7), lineWidth: 1.5)
                            .background(current.paused ? Theme.rose : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        if current.paused {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: DayList.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(current.paused ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("med-sheet-pause")
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Theme.dayText)
                .layoutPriority(1)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DayList.rowHeight)
    }

    private var removeButton: some View {
        Button {
            Haptics.tap()
            confirmRemove = true
        } label: {
            Text("Remove medication")
                .font(.system(size: 17))
                .foregroundStyle(Theme.terraText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.dayCard, in: .rect(cornerRadius: Theme.dayRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("med-sheet-remove")
    }

    // MARK: Actions

    private func saveName() {
        let trimmed = friendly.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current.friendlyName else { return }
        var med = current
        med.friendlyName = trimmed
        store.upsertMedication(med)
    }

    /// The med and its lines move to the other person's text, then both plans are rebuilt.
    private func takenBy(_ role: MedOwner) {
        guard role != current.owner else { return }
        Haptics.select()
        let old = current.owner
        store.moveMedication(current.id, to: role)
        moving = true
        Task {
            await store.reapplyTexts([old, role])
            moving = false
        }
    }
}
