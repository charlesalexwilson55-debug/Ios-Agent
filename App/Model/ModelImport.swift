import Foundation
import ZIPFoundation

/// A bounded-memory ZIP importer. Weights are streamed to disk, never loaded
/// into RAM to unpack. Validate in staging before publishing to the catalog.
enum ModelImport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func copy(_ source: URL, into root: URL) throws {
        let fm = FileManager.default
        let directory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        guard directory || source.pathExtension.lowercased() == "zip" else {
            throw Failure(message: "Choose a ZIP containing the complete MLX model, or its folder. A weights file alone also needs config.json and the tokenizer files.")
        }
        let name = directory ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let destination = root.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw Failure(message: "A model named \(name) already exists. Rename the import or remove the existing model first.")
        }
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        if directory {
            // A regular Files model folder; reject links rather than importing
            // references that will stop resolving outside the security scope.
            let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])
            while let file = enumerator?.nextObject() as? URL {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw Failure(message: "The model folder contains links. Import a complete downloaded copy instead.")
                }
            }
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
        } else {
            let archive = try Archive(url: source, accessMode: .read)
            var bytes: UInt64 = 0
            var count = 0
            for entry in archive {
                count += 1
                guard count <= 10_000, entry.type != .symlink,
                      !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                      !entry.path.split(separator: "/").contains("..") else {
                    throw Failure(message: "This archive contains unsupported paths or links.")
                }
                let (sum, overflow) = bytes.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, sum <= 30_000_000_000 else {
                    throw Failure(message: "This archive is too large to import on the phone.")
                }
                bytes = sum
            }
            let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > Int64(bytes) + 300_000_000 else {
                throw Failure(message: "There is not enough free space to unpack this model. Free space and try again.")
            }
            for entry in archive {
                let target = staging.appendingPathComponent(entry.path).standardizedFileURL
                guard target.path.hasPrefix(staging.path + "/") else {
                    throw Failure(message: "This archive contains an invalid path.")
                }
                if entry.type == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    _ = try archive.extract(entry, to: target, bufferSize: 262_144)
                }
            }
        }
        let models = try modelFolders(in: staging)
        guard models.count == 1, let model = models.first else {
            throw Failure(message: "Choose an archive or folder containing one complete MLX model (config.json, tokenizer files and .safetensors weights).")
        }
        try validate(model)
        if model == staging {
            try fm.moveItem(at: staging, to: destination)
        } else {
            try fm.moveItem(at: model, to: destination)
        }
    }

    private static func modelFolders(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        func visit(_ folder: URL, depth: Int) throws {
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            if files.contains(where: { $0.lastPathComponent == "config.json" || $0.lastPathComponent == "adapter_config.json" }) {
                found.append(folder); return
            }
            guard depth < 4 else { return }
            for file in files where try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try visit(file, depth: depth + 1)
            }
        }
        try visit(root, depth: 0)
        return found
    }

    static func validate(_ folder: URL) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        let names = Set(files.map(\.lastPathComponent))
        let adapter = names.contains("adapter_config.json")
        let config = folder.appendingPathComponent(adapter ? "adapter_config.json" : "config.json")
        guard (try JSONSerialization.jsonObject(with: Data(contentsOf: config))) is [String: Any],
              files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw Failure(message: "The model config or .safetensors weights are missing or invalid.")
        }
        if !adapter && (!names.contains("tokenizer_config.json") || !names.contains("tokenizer.json")) {
            throw Failure(message: "The model needs tokenizer.json and tokenizer_config.json. Include them in the ZIP or folder with the weights.")
        }
        for file in files where file.pathExtension == "safetensors" {
            guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 8 else {
                throw Failure(message: "\(file.lastPathComponent) is empty or incomplete.")
            }
        }
        let index = folder.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: index.path) {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
            guard let shards = json?["weight_map"] as? [String: String], !shards.isEmpty,
                  Set(shards.values).isSubset(of: names) else {
                throw Failure(message: "Some weight shards are missing. Download every file in the model before importing.")
            }
        }
    }
}
