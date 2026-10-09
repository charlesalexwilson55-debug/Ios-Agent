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
    /// Photos assets referenced by this library after an explicit gallery import.
    var galleryAssetIDs: [String]?
    /// Migrates older gallery references into the same searchable index as documents.
    var galleryIndexVersion: Int?
    /// nil on older libraries; true when the user picked a cover explicitly.
    var coverPinned: Bool?

    /// Older libraries predate photoIDs but still keep their cover image.
    var readablePhotoIDs: [UUID] {
        if let photoIDs { return photoIDs }
        if coverPinned == true { return [] }
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
        // A question about a collection must not silently attach one image.
        if ["photo library", "gallery", "camera roll", "all photos", "all pictures",
            "how many photos", "how many pictures", "which photos", "find photos"]
            .contains(where: { text.contains($0) }) { return nil }
        guard ["photo", "picture", "image"].contains(where: { text.contains($0) }) else { return nil }
        let matches = libraries.filter {
            $0.enabled && !$0.name.isEmpty && text.contains($0.name.lowercased()) && !$0.readablePhotoIDs.isEmpty
        }
        if matches.count == 1, matches[0].readablePhotoIDs.count == 1 { return matches[0].readablePhotoIDs.first }
        guard matches.isEmpty,
              ["latest photo", "last photo", "most recent photo", "latest picture", "last picture"]
                .contains(where: { text.contains($0) }) else { return nil }
        let photos = libraries.filter(\.enabled).flatMap(\.readablePhotoIDs)
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
        LibraryMedia.removeFiles(for: library)
    }

    func refresh(_ library: Library) async {
        let found = (try? await KnowledgeIndex.shared.documents(collection: library.collection)) ?? []
        if libraries.contains(where: { $0.id == library.id }) { documents[library.id] = found }
    }

    /// Stable IDs make retries replace passages instead of duplicating them.
    func indexGallery(_ library: Library) async throws {
        while importing[library.id] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let library = libraries.first(where: { $0.id == library.id }),
              library.galleryIndexVersion != 1, let ids = library.galleryAssetIDs, !ids.isEmpty else { return }
        var progress = ImportProgress(total: ids.count)
        importing[library.id] = progress
        defer { importing[library.id] = nil }
        for id in ids {
            try Task.checkCancellation()
            guard libraries.contains(where: { $0.id == library.id }) else { throw CancellationError() }
            progress.current = "Photo \(progress.done + 1)"
            importing[library.id] = progress
            if let photo = PhotoLibraryIndex.shared.record(for: id) {
                let date = photo.date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
                let text = "Photo taken: \(date)\nRecognized text:\n\(photo.text)\nVisual labels: \(photo.labels.joined(separator: ", "))"
                try await KnowledgeIndex.shared.add(id: library.collection + "/gallery/" + id,
                    source: .library, collection: library.collection, title: "\(library.name) · Photo · \(date)", text: text)
                if !libraries.contains(where: { $0.id == library.id }) {
                    try? await KnowledgeIndex.shared.remove(document: library.collection + "/gallery/" + id)
                    throw CancellationError()
                }
            } else {
                progress.failures.append("Photo \(progress.done + 1) could not be indexed")
            }
            progress.done += 1
            await Task.yield()
        }
        if var updated = libraries.first(where: { $0.id == library.id }) {
            updated.galleryIndexVersion = progress.failures.isEmpty ? 1 : nil
            update(updated)
        }
        lastFailures[library.id] = progress.failures.isEmpty ? nil : progress.failures
        await refresh(library)
    }

    func repairGalleryIndexes() async {
        await LibraryMedia.repairPhotos(in: self)
        for library in libraries where library.enabled && library.galleryIndexVersion != 1 {
            do { try await indexGallery(library) }
            catch { Diagnostics.log("library.photo-index failed: \(error.localizedDescription)") }
        }
    }

    func removeDocument(_ document: KnowledgeIndex.Document, from library: Library) async {
        try? await KnowledgeIndex.shared.remove(document: document.id)
        if var updated = libraries.first(where: { $0.id == library.id }) {
            if document.id.hasPrefix(library.collection + "/photo/"),
               let id = UUID(uuidString: String(document.id.dropFirst((library.collection + "/photo/").count))) {
                updated.photoIDs = updated.readablePhotoIDs.filter { $0 != id }
                if updated.coverImageID == id && updated.coverPinned != true { updated.coverImageID = updated.photoIDs?.last }
            }
            if document.id.hasPrefix(library.collection + "/gallery/") {
                let id = String(document.id.dropFirst((library.collection + "/gallery/").count))
                updated.galleryAssetIDs?.removeAll { $0 == id }
            }
            update(updated)
        }
        LibraryMedia.removeFile(document.id, library: library)
        await refresh(library)
    }

    /// Retains originals and indexes text. Images also enter the photo collection.
    func importFiles(_ urls: [URL], into library: Library) async {
        guard importing[library.id] == nil, libraries.contains(where: { $0.id == library.id }) else { return }
        var progress = ImportProgress(total: urls.count)
        importing[library.id] = progress
        defer { importing[library.id] = nil }
        for url in urls {
            if Task.isCancelled || !libraries.contains(where: { $0.id == library.id }) { break }
            progress.current = url.lastPathComponent
            importing[library.id] = progress
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                try await LibraryMedia.importFile(url, into: library, store: self)
            } catch {
                progress.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            progress.done += 1
            importing[library.id] = progress
        }
        lastFailures[library.id] = progress.failures.isEmpty ? nil : progress.failures
        await refresh(library)
    }

    /// Adds typed or pasted text as a note.
    func addNote(title: String, text: String, to library: Library) async throws {
        let id = "\(library.collection)/\(UUID().uuidString)"
        guard libraries.contains(where: { $0.id == library.id }) else { throw CancellationError() }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await KnowledgeIndex.shared.add(id: id, source: .library, collection: library.collection,
                                            title: name.isEmpty ? "Note" : name, text: text)
        if !libraries.contains(where: { $0.id == library.id }) {
            try? await KnowledgeIndex.shared.remove(document: id)
            throw CancellationError()
        }
        await refresh(library)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(libraries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
