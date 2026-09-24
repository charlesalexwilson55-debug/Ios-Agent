import Foundation
import Observation
import Photos
import UIKit
import Vision

/// Searchable, on-device metadata for Photos assets. The original images stay
/// in Photos; only recognized text, broad visual labels and asset IDs are kept.
@MainActor
@Observable
final class PhotoLibraryIndex {
    static let shared = PhotoLibraryIndex()

    struct Record: Codable {
        let assetID: String
        let date: Date?
        let text: String
        let labels: [String]
        let isScreenshot: Bool
    }

    struct SearchResult {
        let matches: [Record]
        let indexed: Int
        let accessible: Int
        let failed: Int
        let limited: Bool
        let terms: [String]
    }

    enum IndexError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Allow Conduit to read Photos in iPhone Settings, then try again."
        }
    }

    private(set) var indexed = 0
    private(set) var total = 0
    private(set) var failed = 0
    private(set) var isIndexing = false
    private var records: [String: Record] = [:]

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-library-index.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
            indexed = saved.count
        }
    }

    @discardableResult
    func indexAll() async throws -> Int {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { throw IndexError.denied }
        if isIndexing {
            while isIndexing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return records.count
        }

        let fetch = PHAsset.fetchAssets(with: .image, options: nil)
        total = fetch.count
        failed = 0
        isIndexing = true
        defer { isIndexing = false; persist() }

        var liveIDs = Set<String>()
        for position in 0..<fetch.count {
            if Task.isCancelled { break }
            let asset = fetch.object(at: position)
            let id = asset.localIdentifier
            liveIDs.insert(id)
            if records[id] != nil { continue }
            guard let data = await Self.thumbnailData(for: asset) else {
                failed += 1
                continue
            }
            let analyzed = await Task.detached(priority: .utility) { Self.analyze(data) }.value
            records[id] = Record(assetID: id, date: asset.creationDate,
                                 text: analyzed.text, labels: analyzed.labels,
                                 isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot))
            indexed = records.count
            if indexed.isMultiple(of: 25) { persist() }
            // Yield between assets. A large camera roll must not freeze the UI.
            await Task.yield()
        }
        if !Task.isCancelled {
            records = records.filter { liveIDs.contains($0.key) }
            indexed = records.count
        }
        return indexed
    }

    func search(_ query: String) async throws -> SearchResult {
        try await indexAll()
        let terms = Self.searchTerms(query)
        let matches = records.values.filter { record in
            let corpus = (record.text + " " + record.labels.joined(separator: " ")).lowercased()
            return !terms.isEmpty && terms.allSatisfy { corpus.contains($0) }
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return SearchResult(matches: matches, indexed: records.count, accessible: total,
                            failed: failed,
                            limited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
                            terms: terms)
    }

    static func isGalleryQuestion(_ request: String) -> Bool {
        let text = request.lowercased()
        let gallery = ["photo library", "gallery", "camera roll", "all photos", "all pictures",
                       "my photos", "my pictures"]
        let operation = ["how many", "count", "find", "search", "which", "show", "look for", "do i have"]
        return gallery.contains(where: { text.contains($0) })
            && operation.contains(where: { text.contains($0) })
    }

    private static func searchTerms(_ query: String) -> [String] {
        let stop: Set<String> = ["how", "many", "count", "find", "search", "which", "show", "look", "for",
            "do", "i", "have", "in", "my", "the", "a", "an", "all", "of", "to", "from", "were", "are",
            "is", "photo", "photos", "picture", "pictures", "image", "images", "library", "gallery",
            "camera", "roll", "message", "messages", "text", "texts", "screenshot", "screenshots"]
        return query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }

    private static func thumbnailData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1200, height: 1200),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.78))
            }
        }
    }

    nonisolated private static func analyze(_ data: Data) -> (text: String, labels: [String]) {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        let classRequest = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: data)
        try? handler.perform([textRequest, classRequest])
        let text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        let labels = (classRequest.results ?? []).filter { $0.confidence >= 0.15 }
            .prefix(8).map(\.identifier)
        return (String(text.prefix(5000)), labels)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}
