import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// An image Conduit made or read.
struct StoredImage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Made by the image generator.
        case created
        /// Attached by the user and read by the image model.
        case read
    }

    var id = UUID()
    var kind: Kind
    /// What was asked for, or what the user said with the photo.
    var prompt: String
    var style: String?
    /// The image model's description, for read images.
    var description: String?
    var date = Date()
    var fileExtension: String
}

/// Every image, kept in the app's own storage.
@MainActor
@Observable
final class ImageStore {
    static let shared = ImageStore()

    /// Newest first.
    private(set) var images: [StoredImage] = []
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var indexURL: URL { folder.appendingPathComponent("index.json") }

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([StoredImage].self, from: data) {
            images = saved
        }
    }

    func url(for image: StoredImage) -> URL {
        Self.folder.appendingPathComponent("\(image.id.uuidString).\(image.fileExtension)")
    }

    func record(id: UUID) -> StoredImage? {
        images.first { $0.id == id }
    }

    /// Saves a picture the user attached. Returns nil when the data is not an image.
    func addPhoto(_ data: Data, prompt: String) -> StoredImage? {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        let stored = StoredImage(kind: .read, prompt: prompt, fileExtension: "jpg")
        return save(jpeg, as: stored)
    }

    /// Saves an image Conduit made.
    func addCreated(_ image: CGImage, prompt: String, style: String) -> StoredImage? {
        guard let png = UIImage(cgImage: image).pngData() else { return nil }
        let stored = StoredImage(kind: .created, prompt: prompt, style: style, fileExtension: "png")
        return save(png, as: stored)
    }

    func setDescription(_ id: UUID, _ description: String) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].description = description
        persist()
    }

    func delete(_ id: UUID) {
        guard let image = record(id: id) else { return }
        try? FileManager.default.removeItem(at: url(for: image))
        images.removeAll { $0.id == id }
        cache.removeObject(forKey: "\(id)-full" as NSString)
        cache.removeObject(forKey: "\(id)-thumb" as NSString)
        persist()
    }

    /// The full picture.
    func image(_ id: UUID) -> UIImage? {
        let key = "\(id)-full" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let record = record(id: id), let image = UIImage(contentsOfFile: url(for: record).path) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A small copy for grids and chat bubbles.
    func thumbnail(_ id: UUID, size: CGFloat = 360) -> UIImage? {
        let key = "\(id)-thumb" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let record = record(id: id),
              let image = Self.downsample(url(for: record), maxPixels: size)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Data for the image model: the longest side no more than `maxPixels`.
    func modelData(_ id: UUID, maxPixels: CGFloat = 1_024) -> Data? {
        guard let record = record(id: id), let image = Self.downsample(url(for: record), maxPixels: maxPixels) else {
            return nil
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    static func downsample(_ url: URL, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func save(_ data: Data, as stored: StoredImage) -> StoredImage? {
        do {
            try data.write(to: url(for: stored), options: .atomic)
        } catch {
            return nil
        }
        images.insert(stored, at: 0)
        persist()
        return stored
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(images) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}
