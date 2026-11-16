import PhotosUI
import SwiftUI

struct MilestoneEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: Milestone?
    @State private var draft: Milestone
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var photoChanged = false
    @State private var confirmDelete = false

    init(milestone: Milestone?) {
        original = milestone
        _draft = State(initialValue: milestone ?? Milestone(title: "", type: .personal, date: .now))
        if let filename = milestone?.photoFilename {
            _photo = State(initialValue: PhotoStore.image(filename))
        }
    }

    private var isNew: Bool { original == nil }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if draft.isPast(store.now) && !isNew {
                    Section {
                        memoryHeader
                    }
                    .listRowBackground(Theme.sageSoft)
                }

                Section {
                    TextField("Title, e.g. First kick!", text: $draft.title)
                        .font(.bloom(.title3, weight: .semibold))
                    Picker("Type", selection: $draft.type) {
                        ForEach(MilestoneType.allCases) { type in
                            Label(type.title, systemImage: type.symbol).tag(type)
                        }
                    }
                } footer: {
                    if draft.isSuggested {
                        Text("Typical; your provider's schedule may differ.")
                    }
                }

                Section {
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    Toggle("Add a time", isOn: $draft.hasTime.animation())
                    if draft.hasTime {
                        DatePicker("Time", selection: $draft.date, displayedComponents: .hourAndMinute)
                    }
                }

                Section("Notes") {
                    TextField("Questions to ask, how you felt, little details…", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Photo") {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipShape(.rect(cornerRadius: 18, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? "Add a photo" : "Change photo", systemImage: "photo.on.rectangle.angled")
                    }
                    if photo != nil {
                        Button("Remove photo", role: .destructive) {
                            withAnimation {
                                photo = nil
                                photoChanged = true
                            }
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete milestone", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .font(.bloom(.body))
            .scrollContentBackground(.hidden)
            .background(CarryBackground())
            .navigationTitle(isNew ? "New milestone" : "Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(!canSave)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        withAnimation {
                            photo = image
                            photoChanged = true
                        }
                    }
                }
            }
            .confirmationDialog("Delete this milestone?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let original { store.delete(original) }
                    Haptics.warning()
                    dismiss()
                }
            }
        }
    }

    private var memoryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Theme.sageDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text("A completed memory")
                    .font(.bloom(.headline, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Add a photo or a note to remember it by.")
                    .font(.bloom(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func save() {
        var milestone = draft
        milestone.title = milestone.title.trimmingCharacters(in: .whitespaces)
        if photoChanged {
            if let old = original?.photoFilename { PhotoStore.delete(old) }
            milestone.photoFilename = photo.flatMap { PhotoStore.save($0) }
        }
        if milestone.createdBy == nil { milestone.createdBy = store.profile?.momName }
        store.upsert(milestone)
        Haptics.success()
        dismiss()
    }
}
