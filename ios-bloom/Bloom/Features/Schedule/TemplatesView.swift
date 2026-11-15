import SwiftUI

/// One person's routines (weekday sets). Each has its own wake, meals, bedtime and medication times.
/// Duplicate is the quickest way to make a new one; no two routines share a day.
struct TemplatesView: View {
    var owner: MedOwner

    @Environment(AppStore.self) private var store
    @State private var showQuiz = false
    @State private var showBox = false
    @State private var pendingDelete: ScheduleTemplate?
    @State private var openTemplate: UUID?

    private var templates: [ScheduleTemplate] { store.templates(for: owner) }
    private var freeDays: Set<Int> { Set(0...6).subtracting(store.takenDays(for: owner, excluding: nil)) }
    private var meds: [Medication] { store.scheduledMedications(for: owner) }
    private var rules: [ScheduleRule] { store.rules(for: owner) }

    var body: some View {
        List {
            if templates.isEmpty {
                Section {
                    Text("No routine yet. Answer a few questions about your day and Bloom places every dose around it.")
                        .font(.bloom(.body))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                ForEach(templates) { t in
                    NavigationLink(value: MedsRoute.editor(t.id)) {
                        TemplateRow(template: t, medCount: t.doses.count, broken: store.violations(in: t).count)
                    }
                    .accessibilityIdentifier("template-\(ScheduleTemplate.daysLabel(t.days))")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = t } label: { Label("Delete", systemImage: "trash") }
                        if !freeDays.isEmpty {
                            Button { duplicate(t) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                .tint(Theme.blushDeep)
                        }
                    }
                    .contextMenu {
                        Button { duplicate(t) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .disabled(freeDays.isEmpty)
                        Button(role: .destructive) { pendingDelete = t } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Routines")
            } footer: {
                Text(freeDays.isEmpty
                     ? "Every day has a routine. To give some days their own, untick them in a routine, then duplicate it."
                     : "\(ScheduleTemplate.daysLabel(freeDays)) \(freeDays.count == 1 ? "has" : "have") no routine yet.")
                    .font(.bloom(.caption))
            }

            Section {
                if let first = templates.first, !freeDays.isEmpty {
                    Button { duplicate(first) } label: {
                        Label("Duplicate for \(ScheduleTemplate.daysLabel(freeDays))", systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier("templates-duplicate")
                }
                Button { Haptics.tap(); showQuiz = true } label: {
                    Label(templates.isEmpty ? "Set up your routine" : "New routine from questions", systemImage: "sun.horizon")
                }
                .disabled(!templates.isEmpty && freeDays.isEmpty)
                .accessibilityIdentifier("templates-new")
            }
            .tint(Theme.blushDeep)
            .font(.bloom(.body, weight: .semibold))

            Section {
                if meds.isEmpty {
                    Text("No medications in the routine yet.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(meds) { med in
                        Text(med.shortName)
                            .font(.bloom(.body, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
                if !rules.isEmpty {
                    ForEach(rules) { rule in
                        Text(store.describe(rule))
                            .font(.bloom(.subheadline))
                            .foregroundStyle(rule.isNoFood ? Theme.coralDeep : Theme.textSecondary)
                    }
                }
                Button { Haptics.tap(); showBox = true } label: {
                    Label("Edit medications & rules", systemImage: "text.badge.checkmark")
                        .font(.bloom(.body, weight: .semibold))
                }
                .tint(Theme.blushDeep)
                .disabled(templates.isEmpty)
                .accessibilityIdentifier("templates-edit-meds")
            } header: {
                Text("Medications & rules")
            }
        }
        .scrollContentBackground(.hidden)
        .duoListClearance()
        .background(BloomBackground())
        .navigationTitle(store.isShared && owner != store.viewerRole ? "\(store.name(for: owner))'s routines" : "Routines")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openTemplate) { ScheduleEditorView(templateID: $0) }
        .sheet(isPresented: $showQuiz) {
            RoutineQuizView(owner: owner, template: nil, days: templates.isEmpty ? nil : freeDays) { saved in
                showQuiz = false
                if saved != nil, store.scheduledMedications(for: owner).isEmpty {
                    Task { try? await Task.sleep(for: .milliseconds(450)); showBox = true }
                }
            }
        }
        .sheet(isPresented: $showBox) {
            MedsBoxView(owner: owner, onClose: { showBox = false })
        }
        .confirmationDialog("Delete the \(pendingDelete.map { ScheduleTemplate.daysLabel($0.days) } ?? "") routine?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                if let pendingDelete { store.deleteTemplate(pendingDelete) }
                Haptics.warning()
                pendingDelete = nil
            }
        } message: {
            Text("Medications on those days won't have planned times until another routine covers them.")
        }
    }

    private func duplicate(_ t: ScheduleTemplate) {
        guard !freeDays.isEmpty else { return }
        Haptics.success()
        let copy = store.duplicateTemplate(t)
        openTemplate = copy.id
    }
}

private struct TemplateRow: View {
    var template: ScheduleTemplate
    var medCount: Int
    var broken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(ScheduleTemplate.daysLabel(template.days))
                    .font(.bloom(.headline, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(ScheduleEngine.clock(template.wake.minutesFromMidnight))–\(ScheduleEngine.clock(template.bed.minutesFromMidnight))")
                    .font(.bloom(.subheadline, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            DayDots(days: template.days)
            Text(summary)
                .font(.bloom(.footnote, weight: .semibold))
                .foregroundStyle(broken > 0 ? Theme.coralDeep : Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts = ["\(template.meals.count) \(template.meals.count == 1 ? "meal" : "meals")",
                     "\(medCount) \(medCount == 1 ? "medication" : "medications")"]
        if broken > 0 { parts.append("\(broken) \(broken == 1 ? "rule" : "rules") not met") }
        return parts.joined(separator: " · ")
    }
}

/// Seven small letters, the routine's days filled.
private struct DayDots: View {
    var days: Set<Int>

    var body: some View {
        let symbols = PregnancyMath.calendar.veryShortWeekdaySymbols
        HStack(spacing: 4) {
            ForEach(ScheduleTemplate.orderedDays, id: \.self) { day in
                let on = days.contains(day)
                Text(symbols[day])
                    .font(.bloom(.caption2, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(on ? .white : Theme.textSecondary)
                    .background(on ? Theme.blush : Theme.surfaceMuted, in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}
