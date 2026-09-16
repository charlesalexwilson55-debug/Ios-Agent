import Foundation
import Observation

/// A model or adapter found on disk.
struct DiscoveredModel: Identifiable, Hashable {
    /// The directory path, which is stable across launches and unique.
    var id: String { directory.path }

    let directory: URL
    let displayName: String
    let sizeBytes: Int64
    /// From config.json, e.g. "qwen3". Nil when the config is unreadable.
    let architecture: String?
    /// Quantisation width from config.json, when the model declares one.
    let quantBits: Int?
    /// True for a LoRA adapter directory rather than a full model.
    let isAdapter: Bool

    var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: sizeBytes)
    }

    /// Flags a model too large to survive on this device.
    ///
    /// Weights are only part of the footprint: the KV cache and transient
    /// workspace add to it during generation, so the practical ceiling is well
    /// under physical RAM. Warning at load time is much kinder than an
    /// out-of-nowhere jetsam kill three tokens into a reply.
    var memoryWarning: String? {
        guard !isAdapter else { return nil }
        let gigabytes = Double(sizeBytes) / 1_073_741_824
        let physical = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        // Weights plus cache and workspace; roughly 1.4x the weights in
        // practice for a short context.
        let projected = gigabytes * 1.4
        if projected > physical * 0.75 {
            return String(format: "This model needs roughly %.1fGB while running, on a device "
                + "with %.0fGB of RAM. iOS will probably terminate Conduit mid-answer. "
                + "A 4-bit model of 4B parameters or smaller is a safer fit.", projected, physical)
        }
        if projected > physical * 0.5 {
            return String(format: "This model needs roughly %.1fGB while running. It should fit, "
                + "but keep other apps closed and expect slower replies as the phone warms up.",
                projected)
        }
        return nil
    }
}

/// Finds models on the device and remembers which one the user picked.
///
/// Two locations are scanned:
///
/// - **Documents** is exposed to the Files app by `UIFileSharingEnabled`, so
///   the user can drag a model folder straight in from a Mac, a USB drive or
///   iCloud Drive. For a 5GB model this is by far the least painful route, and
///   it is the reason that plist key is set.
/// - **Application Support** is where the in-app downloader writes, kept out
///   of Documents so a half-downloaded model is not sitting in the user's
///   file browser looking like something they should open.
@MainActor
@Observable
final class ModelCatalog {
    private(set) var models: [DiscoveredModel] = []
    private(set) var adapters: [DiscoveredModel] = []
    private(set) var isScanning = false

    /// Directory path of the selected model, persisted across launches.
    var selectedModelID: String? {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.selectionKey) }
    }

    /// Optional LoRA adapter layered on the selected model.
    var selectedAdapterID: String? {
        didSet { UserDefaults.standard.set(selectedAdapterID, forKey: Self.adapterKey) }
    }

    private static let selectionKey = "conduit.selectedModel"
    private static let adapterKey = "conduit.selectedAdapter"

    init() {
        selectedModelID = UserDefaults.standard.string(forKey: Self.selectionKey)
        selectedAdapterID = UserDefaults.standard.string(forKey: Self.adapterKey)
    }

    var selectedModel: DiscoveredModel? {
        models.first { $0.id == selectedModelID }
    }

    var selectedAdapter: DiscoveredModel? {
        adapters.first { $0.id == selectedAdapterID }
    }

    // MARK: - Locations

    static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the in-app downloader stores models.
    static var managedRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Multi-gigabyte weights must never go into an iCloud backup: it
            // would blow through the user's storage and slow every backup, for
            // a file that is re-downloadable.
            var marked = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? marked.setResourceValues(values)
        }
        return dir
    }

    // MARK: - Scanning

    func refresh() async {
        isScanning = true
        defer { isScanning = false }

        let roots = [Self.documentsRoot, Self.managedRoot]
        let found = await Task.detached(priority: .userInitiated) {
            Self.scan(roots: roots)
        }.value

        models = found.models.sorted { $0.displayName < $1.displayName }
        adapters = found.adapters.sorted { $0.displayName < $1.displayName }

        // A selection pointing at a deleted folder would silently fail to
        // load, so drop it and fall back to the only model when there is one.
        if let selected = selectedModelID, !models.contains(where: { $0.id == selected }) {
            selectedModelID = nil
        }
        if selectedModelID == nil, models.count == 1 {
            selectedModelID = models[0].id
        }
        if let selected = selectedAdapterID, !adapters.contains(where: { $0.id == selected }) {
            selectedAdapterID = nil
        }
    }

    private struct ScanResult {
        var models: [DiscoveredModel] = []
        var adapters: [DiscoveredModel] = []
    }

    /// Walks the roots two levels deep looking for model directories.
    ///
    /// Two levels, because an unzipped HuggingFace download is usually nested
    /// one folder deeper than the user expects, and an unbounded recursive
    /// walk over a Documents folder that might hold thousands of files is slow
    /// enough to stall the picker.
    private nonisolated static func scan(roots: [URL]) -> ScanResult {
        var result = ScanResult()
        let fm = FileManager.default
        var seen = Set<String>()

        func inspect(_ directory: URL) {
            guard !seen.contains(directory.path) else { return }
            let contents = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let names = Set(contents.map(\.lastPathComponent))

            if names.contains("adapter_config.json"),
               names.contains(where: { $0.hasSuffix(".safetensors") }) {
                seen.insert(directory.path)
                result.adapters.append(DiscoveredModel(
                    directory: directory,
                    displayName: directory.lastPathComponent,
                    sizeBytes: size(of: directory),
                    architecture: nil,
                    quantBits: nil,
                    isAdapter: true
                ))
                return
            }

            // A model directory is config.json plus weights. Checking for both
            // avoids listing a folder that merely holds a tokenizer or a
            // partial download.
            if names.contains("config.json"),
               names.contains(where: { $0.hasSuffix(".safetensors") }) {
                seen.insert(directory.path)
                let config = readConfig(directory.appendingPathComponent("config.json"))
                result.models.append(DiscoveredModel(
                    directory: directory,
                    displayName: directory.lastPathComponent,
                    sizeBytes: size(of: directory),
                    architecture: config.architecture,
                    quantBits: config.quantBits,
                    isAdapter: false
                ))
                return
            }

            for child in contents {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDirectory { inspect(child) }
            }
        }

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            inspect(root)
        }
        return result
    }

    private nonisolated static func readConfig(_ url: URL) -> (architecture: String?, quantBits: Int?) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        let architecture = json["model_type"] as? String
        // MLX writes a `quantization` block; some conversions put bits at the
        // top level instead.
        var bits: Int?
        if let quant = json["quantization"] as? [String: Any] {
            bits = quant["bits"] as? Int
        }
        if bits == nil { bits = json["bits"] as? Int }
        return (architecture, bits)
    }

    private nonisolated static func size(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Importing

    /// Copies a model folder the user picked in the Files browser.
    ///
    /// The picked URL is security-scoped and only readable between the
    /// start/stop access calls, so the folder is copied rather than referenced
    /// in place: a reference would stop resolving on the next launch.
    func importModel(from source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = Self.managedRoot.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        await refresh()
    }

    func delete(_ model: DiscoveredModel) async {
        try? FileManager.default.removeItem(at: model.directory)
        if selectedModelID == model.id { selectedModelID = nil }
        if selectedAdapterID == model.id { selectedAdapterID = nil }
        await refresh()
    }

    // MARK: - Suggested downloads

    /// Models Conduit can fetch itself, by HuggingFace id.
    ///
    /// Sizes are the on-disk weights. Qwen3-8B-4bit is listed because it is
    /// what was asked for, but the 4B is the default recommendation: it leaves
    /// far more headroom on a phone and the accuracy gap on work this shallow
    /// — pick a tool, fill in the arguments — is small.
    struct Suggestion: Identifiable, Hashable {
        var id: String { repoID }
        let repoID: String
        let displayName: String
        let approxBytes: Int64
        let note: String
    }

    static let suggestions: [Suggestion] = [
        Suggestion(
            repoID: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B (4-bit)",
            approxBytes: 2_400_000_000,
            note: "Recommended. Comfortable headroom, quick replies, reliable tool calls."
        ),
        Suggestion(
            repoID: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B (4-bit)",
            approxBytes: 4_600_000_000,
            note: "Stronger reasoning, noticeably slower on a phone, and close to the memory "
                + "ceiling. Keep other apps closed."
        ),
    ]
}
