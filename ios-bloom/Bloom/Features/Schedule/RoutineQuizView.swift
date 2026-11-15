import SwiftUI

/// Asks the person who takes the meds about their day: wake, meals (with rough durations), optional snacks, bed.
/// Creates (or updates) a routine; a first routine covers all 7 days.
struct RoutineQuizView: View {
    var owner: MedOwner
    /// Editing an existing routine; nil creates a new one.
    var template: ScheduleTemplate?
    /// Days for a new routine (defaults to every day not already covered).
    var days: Set<Int>?
    var onDone: (ScheduleTemplate?) -> Void

    @Environment(AppStore.self) private var store

    private enum Step: Int, CaseIterable {
        case wake, breakfast, lunch, dinner, snacks, bed
    }

    @State private var step: Step = .wake
    @State private var wake = DoseTime(hour: 7, minute: 0)
    @State private var bed = DoseTime(hour: 22, minute: 30)
    @State private var breakfast = MealAnswer(name: "Breakfast", time: DoseTime(hour: 7, minute: 30), duration: 20)
    @State private var lunch = MealAnswer(name: "Lunch", time: DoseTime(hour: 12, minute: 30), duration: 30)
    @State private var dinner = MealAnswer(name: "Dinner", time: DoseTime(hour: 19, minute: 0), duration: 40)
    @State private var snacks: [MealAnswer] = []
    @State private var loaded = false

    struct MealAnswer: Equatable, Identifiable {
        var id = UUID()
        var name: String
        var time: DoseTime
        var duration: Int
        var skipped = false
    }

    /// "you" for the viewer, the name otherwise.
    private var isViewer: Bool { !store.isShared || owner == store.viewerRole }
    private var name: String { store.name(for: owner) }

    var body: some View {
        NavigationStack {
            ZStack {
                BloomBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        progress
                        header
                        stepBody
                            .id(step)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) { footer }
            }
            .navigationTitle(template == nil ? "Your routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone(nil) }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: step)
            .onAppear(perform: load)
        }
    }

    // MARK: Pieces

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.blush : Theme.ringTrack)
                    .frame(height: 6)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.bloom(.largeTitle, weight: .bold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(hint)
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var question: String {
        switch step {
        case .wake: isViewer ? "When do you usually wake up?" : "When does \(name) usually wake up?"
        case .breakfast: "Breakfast?"
        case .lunch: "Lunch?"
        case .dinner: "Dinner?"
        case .snacks: "Any regular snacks?"
        case .bed: isViewer ? "And bedtime?" : "And \(name)'s bedtime?"
        }
    }

    private var hint: String {
        switch step {
        case .wake: "Bloom plans every dose around \(isViewer ? "your" : "\(name)'s") day. Rough times are fine."
        case .breakfast, .lunch, .dinner: "Roughly when it starts and how long it takes."
        case .snacks: "Optional. Snacks count as food for no-food windows."
        case .bed: "Nothing gets planned after this."
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .wake:
            timeCard(time: $wake, label: "Wake up", id: "quiz-wake")
        case .breakfast:
            mealCard($breakfast)
        case .lunch:
            mealCard($lunch)
        case .dinner:
            mealCard($dinner)
        case .snacks:
            VStack(spacing: 14) {
                ForEach($snacks) { $snack in
                    mealCard($snack, removable: true)
                }
                if snacks.count < 3 {
                    Button {
                        Haptics.tap()
                        let last = snacks.last?.time.minutesFromMidnight ?? 15 * 60 + 30
                        snacks.append(MealAnswer(name: snacks.isEmpty ? "Snack" : "Snack \(snacks.count + 1)",
                                                 time: DoseTime(minutes: snacks.isEmpty ? last : last + 120), duration: 15))
                    } label: {
                        Label("Add a snack", systemImage: "plus")
                    }
                    .buttonStyle(BloomSoftButtonStyle())
                    .accessibilityIdentifier("quiz-add-snack")
                }
            }
        case .bed:
            timeCard(time: $bed, label: "Bedtime", id: "quiz-bed")
        }
    }

    private func timeCard(time: Binding<DoseTime>, label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.bloom(.headline, weight: .semibold))
                .foregroundStyle(Theme.text)
            DatePicker(label, selection: dateBinding(time), displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(id)
        }
        .bloomCard()
    }

    private func mealCard(_ meal: Binding<MealAnswer>, removable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if removable {
                    TextField("Name", text: meal.name)
                        .font(.bloom(.headline, weight: .semibold))
                } else {
                    Text(meal.wrappedValue.name)
                        .font(.bloom(.headline, weight: .semibold))
                }
                Spacer()
                if removable {
                    Button(role: .destructive) {
                        Haptics.tap()
                        snacks.removeAll { $0.id == meal.wrappedValue.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Remove \(meal.wrappedValue.name)")
                } else {
                    Toggle("I skip it", isOn: meal.skipped)
                        .toggleStyle(.button)
                        .font(.bloom(.footnote, weight: .semibold))
                        .tint(Theme.textSecondary)
                }
            }
            .foregroundStyle(Theme.text)

            if !meal.wrappedValue.skipped {
                DatePicker("Starts at", selection: dateBinding(meal.time), displayedComponents: .hourAndMinute)
                    .font(.bloom(.body, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("quiz-\(meal.wrappedValue.name.lowercased())-time")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Takes about")
                        .font(.bloom(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        ForEach([10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                            let selected = meal.wrappedValue.duration == minutes
                            Button {
                                Haptics.select()
                                meal.wrappedValue.duration = minutes
                            } label: {
                                Text(minutes == 60 ? "1 h" : "\(minutes)")
                                    .font(.bloom(.subheadline, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(selected ? .white : Theme.sageDeep)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(selected ? Theme.sage : Theme.sageSoft, in: .capsule)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    Text("minutes")
                        .font(.bloom(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .bloomCard()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .wake {
                Button {
                    Haptics.tap()
                    step = Step(rawValue: step.rawValue - 1) ?? .wake
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .background(Theme.surface, in: .circle)
                        .foregroundStyle(Theme.text)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Back")
            }
            Button {
                next()
            } label: {
                Text(step == .bed ? (template == nil ? "Build my day" : "Save routine") : (step == .snacks && snacks.isEmpty ? "No snacks" : "Next"))
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .accessibilityIdentifier("quiz-next")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: Logic

    private func dateBinding(_ time: Binding<DoseTime>) -> Binding<Date> {
        Binding(
            get: { time.wrappedValue.date(on: Date.now) },
            set: { time.wrappedValue = DoseTime(date: $0) }
        )
    }

    private func next() {
        Haptics.tap()
        if let following = Step(rawValue: step.rawValue + 1) {
            step = following
        } else {
            finish()
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let template else { return }
        wake = template.wake
        bed = template.bed
        func find(_ word: String) -> ScheduleMeal? { template.meals.first { $0.name.lowercased().contains(word) } }
        if let m = find("breakfast") { breakfast = MealAnswer(id: m.id, name: "Breakfast", time: m.time, duration: m.durationMinutes) } else { breakfast.skipped = true }
        if let m = find("lunch") { lunch = MealAnswer(id: m.id, name: "Lunch", time: m.time, duration: m.durationMinutes) } else { lunch.skipped = true }
        if let m = find("dinner") { dinner = MealAnswer(id: m.id, name: "Dinner", time: m.time, duration: m.durationMinutes) } else { dinner.skipped = true }
        snacks = template.meals.filter { !["breakfast", "lunch", "dinner"].contains(where: $0.name.lowercased().contains) }
            .map { MealAnswer(id: $0.id, name: $0.name, time: $0.time, duration: $0.durationMinutes) }
    }

    private func finish() {
        var meals: [ScheduleMeal] = []
        for answer in [breakfast, lunch, dinner] + snacks where !answer.skipped {
            let trimmed = answer.name.trimmingCharacters(in: .whitespaces)
            meals.append(ScheduleMeal(id: answer.id, name: trimmed.isEmpty ? "Snack" : trimmed, time: answer.time, durationMinutes: answer.duration))
        }
        var t = template ?? ScheduleTemplate(owner: owner, name: "", wake: wake, bed: bed)
        if template == nil {
            let free = Set(0...6).subtracting(store.takenDays(for: owner, excluding: nil))
            t.days = days ?? free
        }
        t.wake = wake
        t.bed = bed.minutesFromMidnight > wake.minutesFromMidnight ? bed : DoseTime(hour: 23, minute: 30)
        t.meals = meals.sorted { $0.time < $1.time }
        t.name = ScheduleTemplate.daysLabel(t.days)
        store.saveTemplate(t, regenerate: true)
        Haptics.success()
        onDone(store.templates.first { $0.id == t.id } ?? t)
    }
}
