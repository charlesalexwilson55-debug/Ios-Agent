import Foundation

// PhotoKit and file UI are replaced; the actual library store and SQLite index run.
@MainActor final class PhotoLibraryIndex {
    static let shared = PhotoLibraryIndex()
    struct Record { let date: Date?; let text: String; let labels: [String] }
    var fixtures: [String: Record] = [:]
    func record(for id: String) -> Record? { fixtures[id] }
}
@MainActor final class ImageStore {
    static let shared = ImageStore()
    struct Image { let id: UUID }
    var images: [Image] = []
}
enum TextExtractor {
    static func text(from url: URL) throws -> String { throw URLError(.unsupportedURL) }
}
enum Diagnostics { static func log(_ text: String) {} }

@MainActor enum LibraryMedia {
    static func removeFiles(for library: Library) {}
    static func removeFile(_ id: String, library: Library) {}
    static func repairPhotos(in store: LibraryStore) async {}
    static func importFile(_ url: URL, into library: Library, store: LibraryStore) async throws {
        throw URLError(.unsupportedURL)
    }
}
