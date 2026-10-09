import Foundation
import UniformTypeIdentifiers

/// Shared pipeline for Photos, Files and repair of older imports.
@MainActor enum LibraryMedia {
    static func folder(_ library: Library) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libraries", isDirectory: true).appendingPathComponent(library.id.uuidString)
    }
    static func importFile(_ url: URL, into library: Library, store: LibraryStore) async throws {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            _ = try await importPhoto(data, into: library, store: store)
            return
        }
        let id = UUID().uuidString
        let destination = folder(library).appendingPathComponent(id).appendingPathComponent(url.lastPathComponent)
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destination)
                return try await TextExtractor.text(from: destination)
            }.value
            try Task.checkCancellation()
            guard store.libraries.contains(where: { $0.id == library.id }) else { throw CancellationError() }
            try await KnowledgeIndex.shared.add(id: library.collection + "/file/" + id, source: .library,
                collection: library.collection, title: url.lastPathComponent, text: text)
            if !store.libraries.contains(where: { $0.id == library.id }) {
                try? await KnowledgeIndex.shared.remove(document: library.collection + "/file/" + id)
                throw CancellationError()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }
    @discardableResult
    static func importPhoto(_ data: Data, into library: Library, store: LibraryStore) async throws -> StoredImage {
        try Task.checkCancellation()
        guard store.libraries.contains(where: { $0.id == library.id }),
              let image = ImageStore.shared.addPhoto(data, prompt: "Imported into \(library.name)") else { throw TextExtractor.ExtractError.empty }
        let analysis = await Task.detached(priority: .utility) { PhotoLibraryIndex.analyze(data) }.value
        let description = "Recognized text:\n\(analysis.text)\nVisual labels: \(analysis.labels.joined(separator: ", "))"
        ImageStore.shared.setDescription(image.id, description)
        do {
            try Task.checkCancellation()
            guard var current = store.libraries.first(where: { $0.id == library.id }) else { throw CancellationError() }
            current.photoIDs = current.readablePhotoIDs + [image.id]
            if current.coverPinned != true { current.coverImageID = image.id }
            store.update(current)
            // Keep the photo when indexing fails, so repair can retry it next time.
            try await index(image: image, description: description, library: current)
            if !store.libraries.contains(where: { $0.id == library.id }) {
                try? await KnowledgeIndex.shared.remove(document: library.collection + "/photo/" + image.id.uuidString)
                ImageStore.shared.delete(image.id)
                throw CancellationError()
            }
            await store.refresh(current)
            return image
        } catch {
            if !store.libraries.contains(where: { $0.id == library.id }) { ImageStore.shared.delete(image.id) }
            throw error
        }
    }
    private static func index(image: StoredImage, description: String, library: Library) async throws {
        try await KnowledgeIndex.shared.add(id: library.collection + "/photo/" + image.id.uuidString,
            source: .library, collection: library.collection,
            title: "\(library.name) · Photo · \(image.date.formatted(date: .abbreviated, time: .shortened))",
            text: "Photo imported: \(image.date.formatted())\n\(description)")
    }
    static func repairPhotos(in store: LibraryStore) async {
        for library in store.libraries where library.enabled && store.importing[library.id] == nil {
            let existing = Set(((try? await KnowledgeIndex.shared.documents(collection: library.collection)) ?? []).map(\.id))
            for id in library.readablePhotoIDs {
                guard !Task.isCancelled, store.libraries.contains(where: { $0.id == library.id }) else { return }
                guard !existing.contains(library.collection + "/photo/" + id.uuidString),
                      let image = ImageStore.shared.record(id: id) else { continue }
                var description = image.description ?? ""
                if description.isEmpty, let data = ImageStore.shared.modelData(id, maxPixels: 2048) {
                    let analysis = await Task.detached { PhotoLibraryIndex.analyze(data) }.value
                    description = "Recognized text:\n\(analysis.text)\nVisual labels: \(analysis.labels.joined(separator: ", "))"
                    ImageStore.shared.setDescription(id, description)
                }
                do {
                    try await index(image: image, description: description, library: library)
                    if !store.libraries.contains(where: { $0.id == library.id }) {
                        try? await KnowledgeIndex.shared.remove(document: library.collection + "/photo/" + id.uuidString)
                    }
                }
                catch { Diagnostics.log("library.photo-repair \(error.localizedDescription)") }
            }
        }
    }
    static func removeFiles(for library: Library) { try? FileManager.default.removeItem(at: folder(library)) }
    static func originalURL(_ document: KnowledgeIndex.Document, library: Library) -> URL? {
        let prefix = library.collection + "/file/"
        guard document.id.hasPrefix(prefix) else { return nil }
        let id = String(document.id.dropFirst(prefix.count))
        guard UUID(uuidString: id) != nil, document.title == URL(fileURLWithPath: document.title).lastPathComponent else { return nil }
        let url = folder(library).appendingPathComponent(id).appendingPathComponent(document.title)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func removeFile(_ id: String, library: Library) {
        let prefix = library.collection + "/file/"
        guard id.hasPrefix(prefix) else { return }
        let suffix = String(id.dropFirst(prefix.count))
        guard UUID(uuidString: suffix) != nil else { return }
        try? FileManager.default.removeItem(at: folder(library).appendingPathComponent(suffix))
    }
}
