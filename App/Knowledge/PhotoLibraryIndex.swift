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

    var allRecords: [Record] {
        records.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func record(for assetID: String) -> Record? { records[assetID] }

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
        let screenshotsOnly = query.localizedCaseInsensitiveContains("screenshot")
        let matches = records.values.filter { record in
            let corpus = (record.text + " " + record.labels.joined(separator: " ")).lowercased()
            return (!screenshotsOnly || record.isScreenshot)
                && (terms.isEmpty || terms.allSatisfy { corpus.contains($0) })
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return SearchResult(matches: matches, indexed: records.count, accessible: total,
                            failed: failed,
                            limited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
                            terms: terms)
    }

    /// Loads one matched photo only when the user asks to inspect it. Bulk
    /// indexing never copies originals into Conduit's storage.
    func imageData(for assetID: String) async -> Data? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await Self.thumbnailData(for: asset)
    }

    func previewData(for assetID: String, size: CGFloat = 320) async -> Data? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await Self.thumbnailData(for: asset, size: size)
    }

    static func isGalleryQuestion(_ request: String) -> Bool {
        let text = request.lowercased()
        let gallery = ["photo library", "gallery", "camera roll", "all photos", "all pictures",
                       "my photos", "my pictures", "screenshot", "photos of", "pictures of",
                       "photo of", "image of"]
        let operation = ["how many", "count", "find", "search", "which", "show", "look for",
                         "do i have", "when did", "when was", "what date", "what time"]
        return gallery.contains(where: { text.contains($0) })
            && operation.contains(where: { text.contains($0) })
    }

    private static func searchTerms(_ query: String) -> [String] {
        let personPattern = #"(?i)\b(?:messages?|texts?|chats?)\s+(?:to|with|from)\s+([\p{L}][\p{L}\p{N}'-]*)"#
        if let regex = try? NSRegularExpression(pattern: personPattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            return [String(query[range]).lowercased()]
        }
        let stop: Set<String> = ["how", "many", "count", "find", "search", "which", "show", "look", "for",
            "do", "did", "when", "was", "take", "took", "if", "there", "theres", "there's", "multiple",
            "them", "any", "i", "have", "in", "my", "the", "a", "an", "all", "of", "to", "from", "were", "are",
            "is", "photo", "photos", "picture", "pictures", "image", "images", "library", "gallery",
            "camera", "roll", "message", "messages", "text", "texts", "screenshot", "screenshots",
            "date", "time", "about", "that", "this", "with", "more", "than", "one"]
        return query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }

    private static func thumbnailData(for asset: PHAsset, size: CGFloat = 1200) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size),
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
