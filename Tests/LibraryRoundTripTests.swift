import XCTest
import UIKit
import PDFKit

/// Runs the production import, OCR, persistence and SQLite retrieval on iOS.
@MainActor final class LibraryRoundTripTests: XCTestCase {
    private func screenshot() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 900)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black]
            ("Rickie" as NSString).draw(at: CGPoint(x: 60, y: 130), withAttributes: attributes)
            ("Bring science notes tomorrow" as NSString).draw(at: CGPoint(x: 60, y: 240), withAttributes: attributes)
        }
        return image.pngData()!
    }
    func testPhotoFromFilesIsVisibleReadableAndRepairable() async throws {
        let store = LibraryStore()
        let library = store.create(name: "Photo round trip", symbol: "photo")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try screenshot().write(to: file)
        await store.importFiles([file], into: library)
        let updated = try XCTUnwrap(store.libraries.first { $0.id == library.id })
        let photoID = try XCTUnwrap(updated.photoIDs?.first)
        XCTAssertNotNil(ImageStore.shared.image(photoID))
        XCTAssertEqual(updated.coverImageID, photoID)
        XCTAssertTrue(store.lastFailures[library.id] == nil)
        var hits = try await KnowledgeIndex.shared.search("Rickie", sources: [.library], collections: [library.collection])
        XCTAssertFalse(hits.isEmpty, "Files-imported photos must be searchable, not just covers")
        let imported = try await KnowledgeIndex.shared.documents(collection: library.collection)
        let document = try XCTUnwrap(imported.first)
        try await KnowledgeIndex.shared.remove(document: document.id)
        await store.repairGalleryIndexes()
        hits = try await KnowledgeIndex.shared.search("Rickie", sources: [.library], collections: [library.collection])
        XCTAssertFalse(hits.isEmpty, "Old retained photos must be reindexed")
        await store.removeDocument(document, from: updated)
        await store.repairGalleryIndexes()
        let remaining = try await KnowledgeIndex.shared.documents(collection: library.collection)
        XCTAssertTrue(remaining.isEmpty, "Deleted photos must not be resurrected by repair")
        await store.delete(library)
        ImageStore.shared.delete(photoID)
        try? FileManager.default.removeItem(at: file)
    }
    func testDocumentsRetainOriginalAndFailWithoutGhostEntries() async throws {
        let store = LibraryStore()
        let library = store.create(name: "Document round trip", symbol: "doc")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("Rickie meeting at noon".utf8).write(to: file)
        await store.importFiles([file, folder.appendingPathComponent("missing.txt")], into: library)
        let documents = try await KnowledgeIndex.shared.documents(collection: library.collection)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(store.lastFailures[library.id]?.count, 1)
        let document = try XCTUnwrap(documents.first)
        let id = String(document.id.split(separator: "/").last!)
        let retained = LibraryMedia.folder(library).appendingPathComponent(id).appendingPathComponent("notes.txt")
        XCTAssertEqual(try Data(contentsOf: retained), Data("Rickie meeting at noon".utf8))
        await store.removeDocument(document, from: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        await store.delete(library)
        try? FileManager.default.removeItem(at: folder)
    }
    func testScannedPDFUsesOCR() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let image = UIImage(data: screenshot())!
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 600))
        let data = renderer.pdfData { context in
            context.beginPage()
            image.draw(in: CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(PDFDocument(url: file)?.page(at: 0)?.string?.isEmpty ?? true)
        let text = try await TextExtractor.text(from: file)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Rickie"))
    }
}
