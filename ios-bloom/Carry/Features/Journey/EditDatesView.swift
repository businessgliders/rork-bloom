import SwiftUI

/// Edit how the pregnancy is dated, or set the due date directly.
struct EditDatesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PregnancyProfile?

    var body: some View {
        Form {
            if let binding = Binding($draft) {
                let profile = binding.wrappedValue
                Section {
                    Picker("Dated by", selection: Binding(
                        get: { profile.datingMethod },
                        set: { draft?.switchMethod(to: $0) }
                    )) {
                        ForEach(DatingMethod.allCases) { Text($0.title).tag($0) }
                    }
                    DatePicker(
                        label(for: profile.datingMethod),
                        selection: binding.datingDate,
                        in: PregnancyMath.allowedRange(for: profile.datingMethod),
                        displayedComponents: .date
                    )
                    if profile.datingMethod == .ivfTransfer {
                        Picker("Embryo age", selection: binding.embryoAgeDays) {
                            Text("Day 3").tag(3)
                            Text("Day 5").tag(5)
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    Text("Due date = ovulation date + 266 days. Weeks count from 14 days before ovulation.")
                }

                Section {
                    DatePicker(
                        "Due date",
                        selection: Binding(
                            get: { profile.dueDate },
                            set: { newDue in
                                draft?.datingMethod = .dueDate
                                draft?.datingDate = newDue
                                draft?.recalculateDueDate()
                            }
                        ),
                        in: PregnancyMath.allowedRange(for: .dueDate),
                        displayedComponents: .date
                    )
                    LabeledContent("Today", value: profile.progress(on: store.now).headline)
                } footer: {
                    Text("Got a due date from your provider? Set it here and Carry will follow it.")
                }
            }
        }
        .font(.bloom(.body))
        .scrollContentBackground(.hidden)
        .background(BloomBackground())
        .navigationTitle("Due date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let draft { store.updateProfile(draft) }
                    Haptics.success()
                    dismiss()
                }
                .fontWeight(.bold)
            }
        }
        .onAppear { if draft == nil { draft = store.profile } }
        .onChange(of: draft?.datingDate) { _, _ in draft?.recalculateDueDate() }
        .onChange(of: draft?.embryoAgeDays) { _, _ in draft?.recalculateDueDate() }
    }

    private func label(for method: DatingMethod) -> String {
        switch method {
        case .ovulation: "Ovulation date"
        case .lmp: "Last period started"
        case .dueDate: "Known due date"
        case .ivfTransfer: "Transfer date"
        }
    }
}
