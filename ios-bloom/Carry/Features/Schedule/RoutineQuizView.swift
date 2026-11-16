import SwiftUI

/// One screen about the day of the person who takes the meds: wake, meals, an optional snack and bedtime.
/// Creates (or updates) a routine; a first routine covers all 7 days.
struct RoutineQuizView: View {
    var owner: MedOwner
    /// Editing an existing routine; nil creates a new one.
    var template: ScheduleTemplate?
    /// Days for a new routine (defaults to every day not already covered).
    var days: Set<Int>?
    var onDone: (ScheduleTemplate?) -> Void

    @Environment(AppStore.self) private var store

    @State private var wake = DoseTime(hour: 7, minute: 0)
    @State private var bed = DoseTime(hour: 22, minute: 30)
    @State private var breakfast = ScheduleMeal(name: "Breakfast", time: DoseTime(hour: 7, minute: 30), durationMinutes: 20)
    @State private var lunch = ScheduleMeal(name: "Lunch", time: DoseTime(hour: 12, minute: 30), durationMinutes: 30)
    @State private var dinner = ScheduleMeal(name: "Dinner", time: DoseTime(hour: 19, minute: 0), durationMinutes: 40)
    @State private var snack = ScheduleMeal(name: "Snack", time: DoseTime(hour: 15, minute: 30), durationMinutes: 15)
    @State private var hasSnack = false
    /// Other meals of an existing routine (extra snacks) are kept as they are.
    @State private var extras: [ScheduleMeal] = []
    @State private var loaded = false

    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }
    private var name: String { store.name(for: owner) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    timeRow("Wake up", systemImage: "sunrise", tint: Theme.peachDeep, time: $wake, id: "quiz-wake")
                    mealRow($breakfast, systemImage: "cup.and.saucer", id: "quiz-breakfast-time")
                    mealRow($lunch, systemImage: "fork.knife", id: "quiz-lunch-time")
                    mealRow($dinner, systemImage: "fork.knife", id: "quiz-dinner-time")
                    Toggle(isOn: $hasSnack.animation()) {
                        Label {
                            Text("Snack")
                                .font(.bloom(.body))
                        } icon: {
                            Image(systemName: "carrot").foregroundStyle(Theme.sageDeep)
                        }
                    }
                    .tint(Theme.blush)
                    .accessibilityIdentifier("quiz-snack")
                    if hasSnack {
                        mealRow($snack, systemImage: "clock", id: "quiz-snack-time", title: "Snack at")
                    }
                    timeRow("Bedtime", systemImage: "moon", tint: Theme.peachDeep, time: $bed, id: "quiz-bed")
                } header: {
                    Text(isViewer ? "When do you usually…" : "When does \(name) usually…")
                } footer: {
                    Text("Rough times are fine. Carry plans every dose around \(isViewer ? "your" : "\(name)'s") day and nothing after bedtime. Snacks count as food for no-food windows.")
                        .font(.bloom(.caption))
                }

                Section {
                    Button {
                        finish()
                    } label: {
                        Text(template == nil ? "Done" : "Save routine")
                    }
                    .buttonStyle(BloomPrimaryButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("quiz-done")
                }
            }
            .navigationTitle(template == nil ? "Your day" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .fontWeight(.semibold)
                        .tint(Theme.blushDeep)
                        .accessibilityIdentifier("quiz-next")
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Rows

    private func timeRow(_ title: String, systemImage: String, tint: Color, time: Binding<DoseTime>, id: String) -> some View {
        DatePicker(selection: dateBinding(time), displayedComponents: .hourAndMinute) {
            Label {
                Text(title).font(.bloom(.body))
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
        .accessibilityIdentifier(id)
    }

    private func mealRow(_ meal: Binding<ScheduleMeal>, systemImage: String, id: String, title: String? = nil) -> some View {
        DatePicker(selection: dateBinding(meal.time), displayedComponents: .hourAndMinute) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title ?? meal.wrappedValue.name).font(.bloom(.body))
                    Text("about \(Medication.durationText(meal.wrappedValue.durationMinutes))")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.sageDeep)
            }
        }
        .accessibilityIdentifier(id)
    }

    private func dateBinding(_ time: Binding<DoseTime>) -> Binding<Date> {
        Binding(
            get: { time.wrappedValue.date(on: Date.now) },
            set: { time.wrappedValue = DoseTime(date: $0) }
        )
    }

    // MARK: Logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let template else { return }
        wake = template.wake
        bed = template.bed
        var rest = template.meals
        func take(_ word: String) -> ScheduleMeal? {
            guard let i = rest.firstIndex(where: { $0.name.lowercased().contains(word) }) else { return nil }
            return rest.remove(at: i)
        }
        if let m = take("breakfast") { breakfast = m }
        if let m = take("lunch") { lunch = m }
        if let m = take("dinner") { dinner = m }
        if let first = rest.first {
            snack = first
            hasSnack = true
            rest.removeFirst()
        }
        extras = rest
    }

    private func finish() {
        var meals = [breakfast, lunch, dinner] + extras
        if hasSnack { meals.append(snack) }
        var t = template ?? ScheduleTemplate(owner: owner, name: "", wake: wake, bed: bed)
        if template == nil {
            let free = Set(0...6).subtracting(store.takenDays(for: owner, excluding: nil))
            t.days = days ?? free
        }
        t.wake = wake
        t.bed = bed.minutesFromMidnight > wake.minutesFromMidnight ? bed : DoseTime(hour: 23, minute: 30)
        t.meals = meals.sorted { $0.time < $1.time }
        store.saveTemplate(t, regenerate: true)
        Haptics.success()
        onDone(store.templates.first { $0.id == t.id } ?? t)
    }
}
