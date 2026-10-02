import Foundation
import Observation
import UIKit

/// Direct-to-device, restartable model installation. The PC never holds the checkpoint.
@MainActor @Observable final class Edge0Download {
    static let shared = Edge0Download()
    enum Tier: String, CaseIterable, Identifiable, Sendable {
        case small = "Edge0 8B", large = "Edge0 35B"
        var id: String { rawValue }
        var repo: String { self == .small ? "Edge0/Edge0-8B-A1B-preview" : "Edge0/Edge0-35B-A3B-preview" }
        var revision: String { self == .small ? "269b9a2c4a69d897c50e9f4e125328481d7c0fcf" : "3fe15cbf2bd5bbcdfd611035e1ac88971ff1cdab" }
        var folder: String { self == .small ? "Edge0-8B" : "Edge0-35B" }
        var architecture: String { self == .small ? "edge0_8b" : "edge0_35b" }
    }
    private(set) var isRunning = false
    private(set) var status = ""
    private(set) var fraction: Double = 0
    private(set) var error: String?
    private var operation: Task<Void, Never>?

    func start(_ tier: Tier, catalog: ModelCatalog) {
        guard !isRunning else { return }
        isRunning = true; error = nil; fraction = 0; status = "Checking storage…"
        UIApplication.shared.isIdleTimerDisabled = true
        let root = ModelCatalog.managedRoot
        operation = Task {
            defer { isRunning = false; UIApplication.shared.isIdleTimerDisabled = false; operation = nil }
            do {
                let worker = Task.detached(priority: .utility) {
                    try await Edge0Installer.install(tier, root: root) { text, value in
                        await MainActor.run { self.status = text; self.fraction = value }
                    }
                }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                status = "\(tier.rawValue) downloaded and verified"
                fraction = 1
                await catalog.refresh()
            } catch is CancellationError {
                status = "Paused. Tap Download again to resume."
            } catch {
                self.error = error.localizedDescription
                status = "Download stopped. Your completed files are saved."
            }
        }
    }
    func cancel() { operation?.cancel() }
}

enum Edge0Installer {
    struct Source {
        let shard: String
        let base: Int64
        let tensor: Edge0Packing.Tensor
    }
    struct RemoteFile: Decodable { let path: String; let size: Int64?; let type: String }
    struct Progress: Codable { let revision: String; var completed: Set<String> }

    static func install(_ tier: Edge0Download.Tier, root: URL,
                        update: @escaping @Sendable (String, Double) async -> Void) async throws {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(tier.folder)
        guard !fm.fileExists(atPath: destination.path) else {
            throw Edge0Packing.Failure(message: "\(tier.rawValue) is already installed.")
        }
        let staging = root.appendingPathComponent(".download-\(tier.folder)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let listingURL = URL(string: "https://huggingface.co/api/models/\(tier.repo)/tree/\(tier.revision)?recursive=true")!
        let (listing, response) = try await session.data(from: listingURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Edge0Packing.Failure(message: "Could not fetch the pinned Edge0 checkpoint.")
        }
        let files = try JSONDecoder().decode([RemoteFile].self, from: listing).filter { $0.type == "file" }
        let sourceFiles = files.filter { $0.path.hasSuffix(".safetensors") || ["config.json", "tokenizer.json", "tokenizer_config.json"].contains($0.path) }
        let total = sourceFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0, total < 25_000_000_000 else { throw Edge0Packing.Failure(message: "Invalid checkpoint size.") }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        // 35B is downloaded as ranges of individual tensors, never entire shards.
        // Allow one large temporary tensor plus conversion workspace and system headroom.
        let progressURL = staging.appendingPathComponent("install-progress.json")
        var progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: progressURL))) ?? Progress(revision: tier.revision, completed: [])
        guard progress.revision == tier.revision else { throw Edge0Packing.Failure(message: "This interrupted download belongs to another checkpoint revision.") }
        // Sparse expert files already have their full logical length after their first
        // tensor. Never count that length as downloaded data when checking a resume.
        let completedFiles = sourceFiles.filter { progress.completed.contains($0.path) }
        let savedFiles = completedFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        if progress.completed.isEmpty || tier == .small {
            try requireSpace(free, needed: max(0, total - savedFiles) + 2_000_000_000, tier: tier)
        } else { try requireSpace(free, needed: 2_000_000_000, tier: tier) }
        func save() throws { try JSONEncoder().encode(progress).write(to: progressURL, options: .atomic) }
        func remote(_ path: String) -> URL { URL(string: "https://huggingface.co/\(tier.repo)/resolve/\(tier.revision)/\(path)")! }

        for file in sourceFiles where !file.path.hasPrefix("model") {
            try Task.checkCancellation()
            let output = staging.appendingPathComponent(file.path)
            if progress.completed.contains(file.path), fileSize(output) == file.size { continue }
            await update("Downloading \(file.path)…", 0)
            let temp = try await download(remote(file.path), session: session, expected: file.size)
            try? fm.removeItem(at: output)
            try fm.moveItem(at: temp, to: output)
            progress.completed.insert(file.path); try save()
        }

        if tier == .small {
            guard let weights = sourceFiles.first(where: { $0.path == "model.safetensors" }) else {
                throw Edge0Packing.Failure(message: "Edge0 8B checkpoint layout changed.")
            }
            let output = staging.appendingPathComponent(weights.path)
            if !progress.completed.contains(weights.path) || fileSize(output) != weights.size {
                await update("Downloading Edge0 8B weights. Keep Conduit open…", 0.05)
                let temp = try await download(remote(weights.path), session: session, expected: weights.size)
                try? fm.removeItem(at: output); try fm.moveItem(at: temp, to: output)
                progress.completed.insert(weights.path); try save()
            }
            try ModelImport.validate(staging)
        } else {
            var sources: [String: Source] = [:]
            let shards = sourceFiles.filter { $0.path.hasPrefix("model-") }.sorted { $0.path < $1.path }
            guard shards.count == 4 else { throw Edge0Packing.Failure(message: "Edge0 35B checkpoint layout changed.") }
            for shard in shards {
                let prefixURL = try await download(remote(shard.path), session: session, range: 0...7, expected: 8)
                let headerSize = try Edge0Packing.uint64(Data(contentsOf: prefixURL))
                try? fm.removeItem(at: prefixURL)
                guard headerSize > 0, headerSize < 64 * 1_048_576 else { throw Edge0Packing.Failure(message: "Invalid checkpoint header.") }
                let headerURL = try await download(remote(shard.path), session: session, range: 8...Int64(7 + headerSize), expected: Int64(headerSize))
                let tensors = try Edge0Packing.header(Data(contentsOf: headerURL))
                try? fm.removeItem(at: headerURL)
                for (name, tensor) in tensors {
                    guard sources[name] == nil, let size = shard.size,
                          tensor.data_offsets[1] <= size - Int64(8 + headerSize) else {
                        throw Edge0Packing.Failure(message: "Checkpoint tensor bounds are invalid.")
                    }
                    sources[name] = Source(shard: shard.path, base: Int64(8 + headerSize), tensor: tensor)
                }
            }
            let experts = try sources.keys.filter { try Edge0Packing.expertPart($0) != nil }
            guard experts.count == 40 * 9 else { throw Edge0Packing.Failure(message: "The checkpoint does not contain all 40 expert layers.") }
            let remaining = sources.filter { !progress.completed.contains($0.key) }.values.reduce(Int64(0)) { $0 + $1.tensor.count }
            let currentFree = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            try requireSpace(currentFree, needed: remaining + 2_000_000_000, tier: tier)
            let residentNames = sources.keys.filter { !experts.contains($0) }.sorted()
            var header: [String: Edge0Packing.Tensor] = [:], cursor: Int64 = 0
            for name in residentNames {
                let tensor = sources[name]!.tensor
                header[name] = Edge0Packing.Tensor(dtype: tensor.dtype, shape: tensor.shape, data_offsets: [cursor, cursor + tensor.count])
                cursor += tensor.count
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(header)
            let residentURL = staging.appendingPathComponent("resident.safetensors")
            if !fm.fileExists(atPath: residentURL.path) {
                fm.createFile(atPath: residentURL.path, contents: Edge0Packing.little(UInt64(encoded.count)) + encoded)
            } else {
                // Header serialization must be stable across resumes, including key order.
                let existing = try FileHandle(forReadingFrom: residentURL)
                defer { try? existing.close() }
                let oldLength = try Edge0Packing.uint64(existing.read(upToCount: 8) ?? Data())
                let oldHeader = try Edge0Packing.header(existing.read(upToCount: Int(oldLength)) ?? Data())
                guard oldHeader.keys.sorted() == header.keys.sorted() else { throw Edge0Packing.Failure(message: "Interrupted model header does not match.") }
                for key in header.keys {
                    guard oldHeader[key]?.data_offsets == header[key]?.data_offsets else { throw Edge0Packing.Failure(message: "Interrupted model offsets do not match.") }
                }
            }
            let residentHandle = try FileHandle(forReadingFrom: residentURL)
            let residentBase = 8 + (try Edge0Packing.uint64(residentHandle.read(upToCount: 8) ?? Data()))
            try residentHandle.close()
            let tensorNames = sources.keys.sorted()
            for (index, name) in tensorNames.enumerated() {
                try Task.checkCancellation()
                if progress.completed.contains(name) { continue }
                let source = sources[name]!
                await update("Preparing Edge0 35B · \(index + 1)/\(tensorNames.count) tensors", Double(index) / Double(tensorNames.count))
                let start = source.base + source.tensor.data_offsets[0]
                let end = source.base + source.tensor.data_offsets[1] - 1
                let temp = try await download(remote(source.shard), session: session, range: start...end, expected: source.tensor.count)
                do {
                    if let part = try Edge0Packing.expertPart(name) {
                        let output = staging.appendingPathComponent(String(format: "experts-L%02d.bin", part.layer))
                        try Edge0Packing.scatter(temp, to: output, part: part.part, tensor: source.tensor)
                    } else {
                        try Edge0Packing.copy(temp, to: residentURL, at: residentBase + UInt64(header[name]!.data_offsets[0]), count: source.tensor.count)
                    }
                } catch { try? fm.removeItem(at: temp); throw error }
                try fm.removeItem(at: temp)
                progress.completed.insert(name); try save()
            }
            await update("Converting tokenizer and trained routing heads…", 0.98)
            try Edge0Packing.tokenizer(staging.appendingPathComponent("tokenizer.json"), to: staging.appendingPathComponent("tokenizer.bin"))
            try Edge0Packing.pregate(staging.appendingPathComponent("prerouter_edge0_35b.safetensors"), to: staging.appendingPathComponent("prerouter-stacked.safetensors"))
            let index: [String: Any] = ["weight_map": Dictionary(uniqueKeysWithValues: residentNames.map { ($0, "resident.safetensors") })]
            try JSONSerialization.data(withJSONObject: index).write(to: staging.appendingPathComponent("model.safetensors.index.json"), options: .atomic)
            try validate35B(staging)
            try? fm.removeItem(at: staging.appendingPathComponent("prerouter_edge0_35b.safetensors"))
        }
        let marker: [String: String] = ["architecture": tier.architecture, "revision": tier.revision, "repo": tier.repo]
        try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent("edge0.json"), options: .atomic)
        try? fm.removeItem(at: progressURL)
        try fm.moveItem(at: staging, to: destination)
        await update("Ready", 1)
    }

    static func validate35B(_ directory: URL) throws {
        for layer in 0..<40 {
            guard fileSize(directory.appendingPathComponent(String(format: "experts-L%02d.bin", layer))) == Edge0Packing.layerBytes else {
                throw Edge0Packing.Failure(message: "Edge0 expert layer \(layer) is missing or incomplete.")
            }
        }
        for name in ["resident.safetensors", "tokenizer.bin", "prerouter-stacked.safetensors", "lora_edge0_35b.safetensors"] {
            guard fileSize(directory.appendingPathComponent(name)) > 8 else { throw Edge0Packing.Failure(message: "Edge0 requires \(name).") }
        }
    }
    static func download(_ url: URL, session: URLSession, range: ClosedRange<Int64>? = nil, expected: Int64?) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                let (temp, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse else { try? FileManager.default.removeItem(at: temp); throw Edge0Packing.Failure(message: "Invalid download response.") }
                let validRange: Bool
                if let range {
                    validRange = http.statusCode == 206 && (http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(range.lowerBound)-\(range.upperBound)/") == true)
                } else { validRange = http.statusCode == 200 }
                guard validRange, expected == nil || fileSize(temp) == expected else {
                    try? FileManager.default.removeItem(at: temp)
                    throw Edge0Packing.Failure(message: "Download was incomplete or the server did not support byte ranges (HTTP \(http.statusCode)).")
                }
                return temp
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 2 { throw error }
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw Edge0Packing.Failure(message: "Download failed.")
    }
    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    static func requireSpace(_ available: Int64, needed: Int64, tier: Edge0Download.Tier) throws {
        guard available > needed else {
            throw Edge0Packing.Failure(message: "\(tier.rawValue) needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) more free space on this iPhone. Available: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)). Remove unused downloads or models, then retry.")
        }
    }
    static func directorySize(_ url: URL) -> Int64 {
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var size: Int64 = 0
        while let file = walker?.nextObject() as? URL { size += fileSize(file) }
        return size
    }
}
