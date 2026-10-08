import CryptoKit
import Foundation
import Observation
import UIKit

/// Downloads pinned, compatible checkpoints onto the phone. No PC staging.
@MainActor @Observable final class SpecialistDownload {
    static let shared = SpecialistDownload()
    enum Model: String, CaseIterable, Identifiable, Sendable {
        case miniCPM = "MiniCPM5 1B · quick text", vision = "Qwen3-VL 2B · images"
        var id: String { rawValue }
        var repo: String { self == .miniCPM ? "openbmb/MiniCPM5-1B-MLX" : "mlx-community/Qwen3-VL-2B-Instruct-4bit" }
        var revision: String { self == .miniCPM ? "9879b18bf2928355fcdf4287635388a3665a40cb" : "9c4f5209e57b31f4b9dfba735de3fb983739c9cc" }
        var folder: String { self == .miniCPM ? "MiniCPM5-1B-MLX" : "Qwen3-VL-2B-Instruct-4bit" }
        var sizeLabel: String { self == .miniCPM ? "618 MB" : "1.80 GB" }
    }
    private(set) var isRunning = false
    private(set) var status = ""
    private(set) var fraction: Double = 0
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func start(_ model: Model, catalog: ModelCatalog) {
        guard !isRunning, !Edge0Download.shared.isRunning else { return }
        isRunning = true; error = nil; fraction = 0; status = "Checking storage…"
        UIApplication.shared.isIdleTimerDisabled = true
        let root = ModelCatalog.managedRoot
        task = Task {
            defer { isRunning = false; task = nil; UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let worker = Task.detached(priority: .utility) {
                    try await SpecialistInstaller.install(model, root: root) { text, value in
                        await MainActor.run { self.status = text; self.fraction = value }
                    }
                }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                status = "Downloaded and verified"; fraction = 1
                await catalog.refresh()
            } catch is CancellationError { status = "Paused. Tap Download to resume completed files." }
            catch { error = error.localizedDescription; status = "Download stopped. Completed files are retained." }
        }
    }
    func cancel() { task?.cancel() }
}

enum SpecialistInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Manifest: Decodable { let siblings: [RemoteFile] }
    struct RemoteFile: Decodable {
        struct LFS: Decodable { let sha256: String }
        let rfilename: String
        let size: Int64
        let lfs: LFS?
    }
    static func install(_ model: SpecialistDownload.Model, root: URL,
                        update: @escaping @Sendable (String, Double) async -> Void) async throws {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(model.folder)
        guard !fm.fileExists(atPath: destination.path) else { return }
        let staging = root.appendingPathComponent(".download-" + model.folder)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = URL(string: "https://huggingface.co/api/models/\(model.repo)/revision/\(model.revision)?blobs=true")!
        let (data, response) = try await session.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "Could not fetch the model manifest.") }
        let files = try JSONDecoder().decode(Manifest.self, from: data).siblings.filter {
            !$0.rfilename.contains("/") && ["json", "jinja", "safetensors", "txt"].contains(URL(fileURLWithPath: $0.rfilename).pathExtension)
        }
        let names = Set(files.map(\.rfilename))
        guard Set(["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]).isSubset(of: names),
              files.allSatisfy({ $0.size > 0 && $0.size < 3_000_000_000 }) else { throw Failure(message: "The checkpoint manifest is incomplete.") }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var retained = Set<String>()
        var completed: Int64 = 0
        for file in files {
            let url = staging.appendingPathComponent(file.rfilename)
            if try valid(url, file: file) { retained.insert(file.rfilename); completed += file.size }
        }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > total - completed + 600_000_000 else { throw Failure(message: "Free more space before downloading this model.") }
        for file in files where !retained.contains(file.rfilename) {
            try Task.checkCancellation()
            await update("Downloading \(file.rfilename)…", Double(completed) / Double(total))
            let remote = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(file.rfilename)")!
            let (temp, reply) = try await session.download(from: remote)
            defer { try? fm.removeItem(at: temp) }
            guard (reply as? HTTPURLResponse)?.statusCode == 200, try valid(temp, file: file) else { throw Failure(message: "Download verification failed for \(file.rfilename).") }
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.rfilename)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temp, to: target)
            completed += file.size
            await update("Verified \(file.rfilename)", Double(completed) / Double(total))
        }
        try ModelImport.validate(staging)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
    }
    private static func valid(_ url: URL, file: RemoteFile) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) == file.size else { return false }
        guard let expected = file.lfs?.sha256 else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
