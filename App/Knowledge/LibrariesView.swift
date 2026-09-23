import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The Libraries page: collections of documents Conduit searches when it
/// answers.
struct LibrariesView: View {
    @State private var store = LibraryStore.shared
    @State private var creating = false
    @State private var opened: Library?

    var body: some View {
        NavigationStack {
            List {
                if store.libraries.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Give Conduit your own reference shelf.")
                                .font(.headline)
                            Text("Add PDFs, school notes, manuals, code, Word, PowerPoint and Excel files, "
                                + "text files or photos of pages. Conduit reads them on the phone, and when you "
                                + "ask something it looks up the most relevant passages and answers from them.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            creating = true
                        } label: {
                            Label("Create a library", systemImage: "plus.circle.fill")
                        }
                    }
                }
                ForEach(store.libraries) { library in
                    Button {
                        opened = library
                    } label: {
                        row(library)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Libraries")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New library")
                }
            }
            .sheet(isPresented: $creating) {
                LibraryEditor(library: nil) { name, symbol in
                    let created = store.create(name: name, symbol: symbol)
                    // Opened once this sheet has finished closing.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        opened = created
                    }
                }
            }
            .sheet(item: $opened) { library in
                LibraryDetailView(libraryID: library.id)
            }
            .task {
                for library in store.libraries { await store.refresh(library) }
            }
        }
    }

    private func row(_ library: Library) -> some View {
        HStack(spacing: 12) {
            Image(systemName: library.symbol)
                .font(.system(size: 18))
                .foregroundStyle(library.enabled ? Color.conduitAccent : Color.secondary)
                .frame(width: 34, height: 34)
                .background { RoundedRectangle(cornerRadius: 9).fill(Color.conduitAccent.opacity(0.12)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name.isEmpty ? "Untitled" : library.name)
                    .foregroundStyle(.primary)
                Text(summary(library))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.importing[library.id] != nil {
                ProgressView()
            }
            Toggle("Use in chats", isOn: Binding(
                get: { library.enabled },
                set: { enabled in
                    var changed = library
                    changed.enabled = enabled
                    store.update(changed)
                }
            ))
            .labelsHidden()
        }
        .contentShape(.rect)
    }

    private func summary(_ library: Library) -> String {
        let documents = store.documents[library.id] ?? []
        let count = documents.count == 1 ? "1 document" : "\(documents.count) documents"
        let passages = documents.reduce(0) { $0 + $1.passages }
        return library.enabled ? "\(count) \u{00B7} \(passages) passages" : "\(count) \u{00B7} not used in chats"
    }
}

/// One library: its documents, adding more, and a search to try it out.
struct LibraryDetailView: View {
    let libraryID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var readingPhotos = false
    @State private var editing = false
    @State private var writingNote = false
    @State private var query = ""
    @State private var hits: [KnowledgeIndex.Hit] = []
    @State private var searching = false
    @State private var confirmDelete = false

    private var library: Library? {
        store.libraries.first { $0.id == libraryID }
    }

    var body: some View {
        NavigationStack {
            if let library {
                content(library)
            } else {
                ContentUnavailableView("Library deleted", systemImage: "books.vertical")
            }
        }
    }

    private func content(_ library: Library) -> some View {
        List {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Add files", systemImage: "doc.badge.plus")
                }
                Button {
                    writingNote = true
                } label: {
                    Label("Write or paste a note", systemImage: "square.and.pencil")
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                    Label("Add photos from gallery", systemImage: "photo.on.rectangle")
                }
                .disabled(readingPhotos)
                if readingPhotos {
                    HStack { ProgressView(); Text("Reading text from photos on this iPhone…") }
                }
                if let progress = store.importing[library.id] {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        Text("Reading \(progress.current) (\(progress.done + 1) of \(progress.total))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failures = store.lastFailures[library.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Some files could not be added")
                            .font(.subheadline.weight(.semibold))
                        ForEach(failures, id: \.self) { failure in
                            Text(failure).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Dismiss") { store.lastFailures[library.id] = nil }
                            .font(.footnote)
                    }
                }
            } footer: {
                Text("PDF, Word, PowerPoint, Excel, text, Markdown, code, web pages, ZIP archives and photos "
                    + "of text. Apple Vision reads photos on this iPhone; text is indexed locally.")
            }

            Section("Try a search") {
                HStack {
                    TextField("Ask something this library covers", text: $query)
                        .submitLabel(.search)
                        .onSubmit { search(library) }
                    if searching { ProgressView() }
                }
                ForEach(hits) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.title).font(.subheadline.weight(.semibold))
                        Text(hit.text).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
            }

            Section("Documents") {
                let documents = store.documents[library.id] ?? []
                if documents.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                        Text("\(document.passages) passages \u{00B7} "
                            + document.added.formatted(date: .abbreviated, time: .omitted))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task { await store.removeDocument(document, from: library) }
                        }
                    }
                }
            }

            Section {
                Button("Rename or change icon") { editing = true }
                Button("Delete library", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(library.name.isEmpty ? "Library" : library.name)
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty, !readingPhotos else { return }
            readingPhotos = true
            Task {
                var failures: [String] = []
                for (index, photo) in selection.enumerated() {
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else {
                            throw TextExtractor.ExtractError.empty
                        }
                        let text = try await TextExtractor.imageText(data)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw TextExtractor.ExtractError.empty
                        }
                        try await store.addNote(title: "Photo \(index + 1) · \(Date().formatted(date: .abbreviated, time: .shortened))", text: text, to: library)
                    } catch {
                        failures.append("Photo \(index + 1): \(error.localizedDescription)")
                    }
                }
                if !failures.isEmpty { store.lastFailures[library.id] = failures }
                photos = []
                readingPhotos = false
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: TextExtractor.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await store.importFiles(urls, into: library) }
            }
        }
        .sheet(isPresented: $editing) {
            LibraryEditor(library: library) { name, symbol in
                var changed = library
                changed.name = name
                changed.symbol = symbol
                store.update(changed)
            }
        }
        .sheet(isPresented: $writingNote) {
            NoteEditor { title, text in
                Task { try? await store.addNote(title: title, text: text, to: library) }
            }
        }
        .confirmationDialog("Delete \(library.name) and everything in it?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await store.delete(library) }
                dismiss()
            }
        }
        .task { await store.refresh(library) }
    }

    private func search(_ library: Library) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            hits = (try? await KnowledgeIndex.shared.search(
                text, sources: [.library], collections: [library.collection], limit: 5)) ?? []
            searching = false
        }
    }
}

/// Naming a library and picking its icon.
struct LibraryEditor: View {
    let library: Library?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = Library.symbols[0]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, for example Year 12 Physics", text: $name)
                    .textInputAutocapitalization(.words)
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(Library.symbols, id: \.self) { item in
                            Button {
                                symbol = item
                            } label: {
                                Image(systemName: item)
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: 44)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(item == symbol ? Color.conduitAccent.opacity(0.25) : Color.clear)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(library == nil ? "New library" : "Edit library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, symbol)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let library {
                    name = library.name
                    symbol = library.symbol
                }
            }
        }
    }
}

/// Typing or pasting a note into a library.
struct NoteEditor: View {
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Write or paste the note", text: $text, axis: .vertical)
                    .lineLimit(8...30)
            }
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
