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

    /// Image-reading models, which are not chat models. Qwen3.5 is left out:
    /// its checkpoints on the phone are text-only.
    static let visionArchitectures: Set<String> = [
        "qwen3_vl", "qwen2_vl", "qwen2_5_vl", "smolvlm", "fastvlm", "llava_qwen2", "lfm2_vl",
        "lfm2-vl", "idefics3", "paligemma", "glm_ocr", "pixtral",
    ]

    var isVisionModel: Bool {
        architecture.map { Self.visionArchitectures.contains($0) } ?? false
    }

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
/// - **Application Support** is where imported copies land, kept out of
///   Documents so a partially-copied model is not sitting in the user's file
///   browser looking like something they should open.
@MainActor
@Observable
final class ModelCatalog {
    private(set) var models: [DiscoveredModel] = []
    private(set) var adapters: [DiscoveredModel] = []
    /// Image-reading models found on the phone.
    private(set) var visionModels: [DiscoveredModel] = []
    private(set) var isScanning = false

    /// Directory path of the selected model, persisted across launches.
    ///
    /// Written through `select(modelID:)` rather than a `didSet` observer:
    /// the `@Observable` macro rewrites stored properties into computed
    /// accessors so it can track reads and writes, which leaves nowhere for a
    /// property observer to live. An explicit setter also makes the
    /// persistence side effect visible at the call site instead of hiding it
    /// behind an assignment.
    private(set) var selectedModelID: String?

    /// Optional LoRA adapter layered on the selected model.
    private(set) var selectedAdapterID: String?

    private static let selectionKey = "conduit.selectedModel"
    private static let adapterKey = "conduit.selectedAdapter"

    func select(modelID: String?) {
        selectedModelID = modelID
        UserDefaults.standard.set(modelID, forKey: Self.selectionKey)
    }

    func select(adapterID: String?) {
        selectedAdapterID = adapterID
        UserDefaults.standard.set(adapterID, forKey: Self.adapterKey)
    }

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

    /// Where imported models are copied to.
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

        models = found.models.filter { !$0.isVisionModel }.sorted { $0.displayName < $1.displayName }
        visionModels = found.models.filter(\.isVisionModel).sorted { $0.displayName < $1.displayName }
        adapters = found.adapters.sorted { $0.displayName < $1.displayName }

        // A selection pointing at a deleted folder would silently fail to
        // load, so drop it and fall back to the only model when there is one.
        if let selected = selectedModelID, !models.contains(where: { $0.id == selected }) {
            select(modelID: nil)
        }
        if selectedModelID == nil, models.count == 1 {
            select(modelID: models[0].id)
        }
        if let selected = selectedAdapterID, !adapters.contains(where: { $0.id == selected }) {
            select(adapterID: nil)
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

            if names.contains("adapter_config.json"), validWeights(in: directory, names: names) {
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

            // Check every safetensors payload against its header. A USB copy
            // interrupted mid-file still has config.json and a weight filename;
            // listing it as a model would fail during loading or battery swap.
            if names.contains("config.json"), validWeights(in: directory, names: names) {
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

    private nonisolated static func validWeights(in directory: URL, names: Set<String>) -> Bool {
        let weightNames = Set(names.filter { $0.hasSuffix(".safetensors") })
        guard !weightNames.isEmpty else { return false }
        if names.contains("model.safetensors.index.json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json")),
                  let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = index["weight_map"] as? [String: String], !map.isEmpty
            else { return false }
            guard Set(map.values).isSubset(of: weightNames) else { return false }
        }
        for name in weightNames {
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else {
                return false
            }
            let headerLength = prefix.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << (8 * $1.offset))
            }
            guard headerLength > 0, headerLength < 64 * 1_048_576,
                  let header = try? handle.read(upToCount: Int(headerLength)),
                  header.count == Int(headerLength),
                  let tensors = try? JSONSerialization.jsonObject(with: header) as? [String: Any]
            else { return false }
            let lastByte = tensors.compactMap { key, value -> Int64? in
                guard key != "__metadata__", let tensor = value as? [String: Any],
                      let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2
                else { return nil }
                return offsets[1].int64Value
            }.max()
            guard let lastByte,
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  Int64(size) >= Int64(8 + headerLength) + lastByte
            else { return false }
        }
        return true
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

        let root = Self.managedRoot
        try await Task.detached(priority: .userInitiated) {
            try ModelImport.copy(source, into: root)
        }.value
        await refresh()
    }

    func delete(_ model: DiscoveredModel) async {
        try? FileManager.default.removeItem(at: model.directory)
        if selectedModelID == model.id { select(modelID: nil) }
        if selectedAdapterID == model.id { select(adapterID: nil) }
        await refresh()
    }

    // MARK: - Suggested downloads

    /// Models worth copying onto the phone, by HuggingFace id.
    ///
    /// Sizes are the on-disk weights. Qwen3.5 4B is the default: it follows
    /// instructions and calls tools far more reliably than Qwen3 4B at a
    /// similar size, and only a quarter of its layers keep a per-token cache,
    /// so long answers cost much less memory. The 9B is stronger still but
    /// needs the increased-memory entitlement to load on a phone.
    struct Suggestion: Identifiable, Hashable {
        var id: String { repoID }
        let repoID: String
        let displayName: String
        let approxBytes: Int64
        let note: String
    }

    static let suggestions: [Suggestion] = [
        Suggestion(
            repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5 4B (4-bit)",
            approxBytes: 3_030_000_000,
            note: "Recommended. Best tool use and reasoning that fits comfortably."
        ),
        Suggestion(
            repoID: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen3 4B (4-bit)",
            approxBytes: 2_260_000_000,
            note: "Smaller and a little faster, but weaker at following instructions."
        ),
        Suggestion(
            repoID: "mlx-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen3.5 9B (4-bit)",
            approxBytes: 5_950_000_000,
            note: "Strongest, but needs the increased-memory entitlement and all other "
                + "apps closed. Slow on a phone."
        ),
    ]
}
