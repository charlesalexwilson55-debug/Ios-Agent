import Foundation
import Observation

/// A named collection of documents the model can look things up in.
struct Library: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var symbol = "books.vertical"
    /// Whether chats search it.
    var enabled = true
    var created = Date()
    /// A locally stored gallery photo used on the grid card.
    var coverImageID: UUID?
    /// Gallery photos kept for visual questions. Optional for older saved libraries.
    var photoIDs: [UUID]?
    /// nil on older libraries; true when the user picked a cover explicitly.
    var coverPinned: Bool?

    /// Older libraries predate photoIDs but still keep their cover image.
    var readablePhotoIDs: [UUID] {
        if let photoIDs, !photoIDs.isEmpty { return photoIDs }
        return coverImageID.map { [$0] } ?? []
    }

    var collection: String { "library:\(id.uuidString)" }

    static let symbols = [
        "books.vertical", "graduationcap", "wrench.and.screwdriver", "chevron.left.forwardslash.chevron.right",
        "note.text", "briefcase", "heart.text.square", "flask", "globe.europe.africa", "music.note",
    ]
}

/// The libraries, their documents, and imports in progress.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    struct ImportProgress: Equatable {
        var current = ""
        var done = 0
        var total = 0
        var failures: [String] = []
    }

    private(set) var libraries: [Library] = []
    private(set) var documents: [UUID: [KnowledgeIndex.Document]] = [:]
    private(set) var importing: [UUID: ImportProgress] = [:]
    /// The last import's problems, per library, until dismissed.
    var lastFailures: [UUID: [String]] = [:]

    private static let key = "conduit.libraries"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Library].self, from: data) {
            libraries = saved
        }
    }

    /// Collections chats may search.
    var enabledCollections: Set<String> {
        Set(libraries.filter(\.enabled).map(\.collection))
    }

    /// Attach a library photo only when the request identifies a library or
    /// explicitly asks about the latest photo. Never guess between libraries.
    func photoID(for request: String) -> UUID? {
        let text = request.lowercased()
        guard ["photo", "picture", "image"].contains(where: { text.contains($0) }) else { return nil }
        let matches = libraries.filter {
            !$0.name.isEmpty && text.contains($0.name.lowercased()) && !$0.readablePhotoIDs.isEmpty
        }
        if matches.count == 1 { return matches[0].readablePhotoIDs.last }
        guard matches.isEmpty,
              ["latest photo", "last photo", "most recent photo", "latest picture", "last picture"]
                .contains(where: { text.contains($0) }) else { return nil }
        let photos = libraries.flatMap(\.readablePhotoIDs)
        return ImageStore.shared.images.first(where: { photos.contains($0.id) })?.id
    }

    func name(ofCollection collection: String) -> String? {
        libraries.first { $0.collection == collection }?.name
    }

    @discardableResult
    func create(name: String, symbol: String) -> Library {
        let library = Library(name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol)
        libraries.append(library)
        persist()
        return library
    }

    func update(_ library: Library) {
        guard let index = libraries.firstIndex(where: { $0.id == library.id }) else { return }
        libraries[index] = library
        persist()
    }

    func delete(_ library: Library) async {
        libraries.removeAll { $0.id == library.id }
        documents[library.id] = nil
        persist()
        try? await KnowledgeIndex.shared.remove(collection: library.collection)
    }

    func refresh(_ library: Library) async {
        documents[library.id] = (try? await KnowledgeIndex.shared.documents(collection: library.collection)) ?? []
    }

    func removeDocument(_ document: KnowledgeIndex.Document, from library: Library) async {
        try? await KnowledgeIndex.shared.remove(document: document.id)
        await refresh(library)
    }

    /// Reads each file, then indexes its text. Files are not copied: only
    /// their text is kept, in the index.
    func importFiles(_ urls: [URL], into library: Library) async {
        var progress = ImportProgress(total: urls.count)
        importing[library.id] = progress
        for url in urls {
            progress.current = url.lastPathComponent
            importing[library.id] = progress
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try await TextExtractor.text(from: url)
                }.value
                let id = "\(library.collection)/\(UUID().uuidString)"
                try await KnowledgeIndex.shared.add(id: id, source: .library, collection: library.collection,
                                                    title: url.lastPathComponent, text: text)
            } catch {
                progress.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            progress.done += 1
            importing[library.id] = progress
        }
        importing[library.id] = nil
        lastFailures[library.id] = progress.failures.isEmpty ? nil : progress.failures
        await refresh(library)
    }

    /// Adds typed or pasted text as a note.
    func addNote(title: String, text: String, to library: Library) async throws {
        let id = "\(library.collection)/\(UUID().uuidString)"
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await KnowledgeIndex.shared.add(id: id, source: .library, collection: library.collection,
                                            title: name.isEmpty ? "Note" : name, text: text)
        await refresh(library)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(libraries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
