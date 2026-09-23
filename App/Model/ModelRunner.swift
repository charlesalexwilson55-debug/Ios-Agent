import Foundation
import MLX
import MLXLLM
import MLXLMCommon
// mlx-swift-lm 3.31.4 ships no concrete tokenizer loader. MLXHuggingFace
// provides the #huggingFaceTokenizerLoader() macro, and its expansion calls
// Tokenizers.AutoTokenizer directly — so `import Tokenizers` (swift-transformers)
// is required here for the expanded code to compile, even though nothing in
// this file names that module explicitly.
import MLXHuggingFace
import Tokenizers
import os

/// The only file that touches MLX.
///
/// Everything above this layer speaks in `RunnerEvent` and `ArgumentValue`, so
/// the agent loop, the tools and the UI carry no dependency on the inference
/// framework. MLXLMCommon defines `ToolSpec`, `JSONValue`, `ToolCall` and
/// `Chat`; swift-transformers defines several of the same names. Ours are
/// `ToolDescriptor` and `ArgumentValue`, and framework names are qualified.
actor ModelRunner {

    /// What the agent loop consumes. No MLX types cross this boundary.
    enum RunnerEvent {
        /// Answer text, with any thinking already removed.
        case text(String)
        /// Qwen3 `<think>` content, delivered separately so the UI can fold it
        /// away and the history can leave it out.
        case reasoning(String)
        /// `id` is whatever the framework assigned, which may be nil; the
        /// agent loop assigns its own when it is.
        case toolCall(id: String?, name: String, arguments: ArgumentValue)
        case finished(tokensPerSecond: Double?)
    }

    enum RunnerError: LocalizedError {
        case noModelLoaded
        case loadFailed(String)
        case generationFailed(String)
        case insufficientMemory(String)

        var errorDescription: String? {
            switch self {
            case .noModelLoaded:
                return "No model is loaded. Pick one from the model list first."
            case .loadFailed(let why):
                return "The model could not be loaded: \(why)"
            case .generationFailed(let why):
                return "Generation failed: \(why)"
            case .insufficientMemory(let why):
                return why
            }
        }
    }

    private var container: ModelContainer?
    private var loadedDirectory: String?

    /// Bytes of KV cache per generated token for the loaded model, from its
    /// config.json. Drives the memory budget below.
    private var kvBytesPerToken = 150_000

    /// Human-readable name of what is loaded, used in the system prompt.
    private(set) var loadedName: String = "a local model"

    /// What was last loaded, so the model can be put aside while the image
    /// model runs and brought back afterwards.
    private var lastLoad: (directory: URL, name: String, adapter: URL?)?
    private(set) var isSuspended = false

    var isLoaded: Bool { container != nil }

    struct Configuration: Sendable {
        let directory: URL
        let name: String
        let adapter: URL?
    }
    func configuration() -> Configuration? {
        lastLoad.map { Configuration(directory: $0.directory, name: $0.name, adapter: $0.adapter) }
    }

    // MARK: - Memory policy
    //
    // The crash on long or difficult answers is iOS terminating the app for
    // exceeding its memory limit. MLX does not know that limit exists: its own
    // ceiling defaults to 1.5x the GPU's recommended working set, which on an
    // iPhone is far past what iOS allows a single app. So MLX keeps growing the
    // KV cache until iOS kills the process, with no error and no chance to stop.
    //
    // The fix is to ask iOS how much headroom is left
    // (os_proc_available_memory) and budget against that:
    // - the KV cache is stored at 8 bits, roughly halving the cost of each token,
    // - the prompt is prefilled in smaller steps to lower the peak,
    // - the answer length is capped to what the remaining memory can hold,
    // - MLX's own limit is set just under the real ceiling, so it frees cached
    //   buffers and waits instead of allocating past it,
    // - and a request that cannot fit is refused with a message, not a crash.

    private static let megabyte = 1_048_576
    private static let kvBits = 8
    private static let prefillStepSize = 256
    /// Kept free for SwiftUI, the tokenizer, the JavaScript sandbox and the
    /// transient activations of each forward pass.
    private static let reserveBytes = 450 * megabyte
    /// Scratch memory needed while the prompt is being processed.
    private static let prefillWorkspaceBytes = 200 * megabyte
    /// Below this many tokens of room an answer is not worth starting.
    private static let minimumAnswerTokens = 128

    /// Memory left before iOS terminates the app, or nil where the API does
    /// not apply (it returns 0 off-device).
    private static func availableMemory() -> Int? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes) : nil
    }

    private static func estimateKVBytesPerToken(directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Multimodal checkpoints (Qwen3.5, Gemma 4) nest the language model's
        // settings under text_config.
        let json = root["text_config"] as? [String: Any] ?? root
        guard let layers = json["num_hidden_layers"] as? Int else { return nil }
        // Only full-attention layers grow with every token. Qwen3.5's linear
        // layers keep a fixed-size state, and sliding-window layers stop
        // growing at the window, so they are left out of the per-token cost.
        let growingLayers: Int
        if let types = json["layer_types"] as? [String] {
            growingLayers = types.filter { $0 == "full_attention" }.count
        } else if let interval = json["full_attention_interval"] as? Int, interval > 0 {
            growingLayers = layers / interval
        } else {
            growingLayers = layers
        }
        let heads = json["num_attention_heads"] as? Int ?? 32
        let kvHeads = json["num_key_value_heads"] as? Int ?? heads
        let hidden = json["hidden_size"] as? Int ?? 4096
        let headDim = json["head_dim"] as? Int ?? hidden / max(heads, 1)
        let elements = max(growingLayers, 1) * kvHeads * headDim * 2
        // Quantised values plus a 16-bit scale and bias per 64-element group.
        let bytesPerElement = Double(kvBits) / 8 + 4.0 / 64
        return Int(Double(elements) * bytesPerElement)
    }

    // MARK: - Loading

    /// Loads a model from a local directory with the overload that cannot
    /// reach the network.
    func load(directory: URL, displayName: String, adapterDirectory: URL? = nil) async throws {
        let signature = directory.path + "|" + (adapterDirectory?.path ?? "")
        if loadedDirectory == signature, container != nil { return }

        // Release the previous model first. Two multi-gigabyte models resident
        // at once is an immediate termination on a phone.
        container = nil
        loadedDirectory = nil
        MLX.Memory.clearCache()
        MLX.Memory.cacheLimit = 32 * Self.megabyte

        // Refuse up front when the weights alone cannot fit, instead of letting
        // iOS kill the app halfway through loading them.
        if let headroom = Self.availableMemory() {
            let weights = Self.weightsSize(directory)
            if weights + Self.reserveBytes > headroom {
                throw RunnerError.insufficientMemory(String(
                    format: "This model needs about %.1f GB but only %.1f GB is available to "
                        + "Conduit. Close other apps, or choose a smaller model.",
                    Double(weights) / 1e9, Double(headroom) / 1e9))
            }
        }

        Diagnostics.begin("load", "model=\(displayName) "
            + "weights=\(Diagnostics.megabytes(Self.weightsSize(directory)))MB "
            + "adapter=\(adapterDirectory?.lastPathComponent ?? "none") "
            + "avail=\(Diagnostics.availableMB)MB")
        do {
            // The LLM factory explicitly: the generic loader tries the vision
            // factory first, which would load a text-only Qwen3.5 checkpoint
            // twice before giving up on it.
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
            if let adapterDirectory {
                try await Self.applyAdapter(at: adapterDirectory, to: loaded)
            }
            container = loaded
            loadedDirectory = signature
            loadedName = displayName
            lastLoad = (directory, displayName, adapterDirectory)
            isSuspended = false
            kvBytesPerToken = Self.estimateKVBytesPerToken(directory: directory) ?? 150_000
            Diagnostics.end("load", "ok kvBytesPerToken=\(kvBytesPerToken) "
                + "active=\(Diagnostics.megabytes(MLX.Memory.activeMemory))MB "
                + "avail=\(Diagnostics.availableMB)MB")
        } catch {
            container = nil
            Diagnostics.end("load", "failed: \(error.localizedDescription)")
            throw RunnerError.loadFailed(error.localizedDescription)
        }
    }

    private static func weightsSize(_ directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { $0.pathExtension == "safetensors" }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
    }

    /// Layers a LoRA adapter onto the loaded model. PEFT adapters (what
    /// Unsloth and `peft` write) and MLX-native adapters are both accepted.
    private static func applyAdapter(at directory: URL, to container: ModelContainer) async throws {
        let adapter: LoRAContainer = try isPEFTAdapter(directory)
            ? LoRAContainer.fromPEFT(directory: directory)
            : LoRAContainer.from(directory: directory)

        // The explicit parameter type selects the ModelContext overload of perform.
        try await container.perform { (context: ModelContext) in
            try adapter.load(into: context.model)
        }
    }

    private static func isPEFTAdapter(_ directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("adapter_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["peft_type"] != nil
    }

    func unload() {
        container = nil
        loadedDirectory = nil
        loadedName = "a local model"
        lastLoad = nil
        isSuspended = false
        MLX.Memory.clearCache()
    }

    /// Frees the chat model's memory, remembering it for `resume()`.
    func suspend() {
        guard container != nil else { return }
        container = nil
        loadedDirectory = nil
        isSuspended = true
        MLX.Memory.clearCache()
        Diagnostics.log("model.suspend avail=\(Diagnostics.availableMB)MB")
    }

    /// Brings back a suspended chat model.
    func resume() async throws {
        guard isSuspended, let lastLoad else { return }
        try await load(directory: lastLoad.directory, displayName: lastLoad.name,
                       adapterDirectory: lastLoad.adapter)
    }

    // MARK: - Generation

    /// Streams one assistant turn.
    ///
    /// `nonisolated` so callers can write `for try await event in
    /// runner.stream(...)` directly; the isolated work happens in the Task.
    nonisolated func stream(
        messages: [Message],
        tools: [ToolDescriptor],
        thinking: Bool,
        sampling: Sampling = .chat
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(
                        messages: messages, tools: tools, thinking: thinking, sampling: sampling
                    ) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How a generation samples. `.chat` is Qwen3's published setting for
    /// conversation; `.extraction` is for short, structured work such as
    /// the research checks, where wandering wording breaks the parser.
    enum Sampling: Sendable {
        case chat
        case extraction(maxTokens: Int)
    }

    private func generate(
        messages: [Message],
        tools: [ToolDescriptor],
        thinking: Bool,
        sampling: Sampling,
        onEvent: @Sendable @escaping (RunnerEvent) -> Void
    ) async throws {
        // A model put aside for the image model comes back on first use.
        if container == nil, isSuspended { try await resume() }
        guard let container else { throw RunnerError.noModelLoaded }

        let input = UserInput(
            chat: messages.map { $0.asChatMessage },
            tools: tools.map(\.functionSchema),
            additionalContext: ["enable_thinking": thinking]
        )

        // Thinking needs room: reasoning often runs to a few thousand tokens
        // before the answer begins. Code answers are long too.
        var requestedTokens = thinking ? 4096 : 1536
        var temperature: Float = thinking ? 0.6 : 0.7
        if case .extraction(let limit) = sampling {
            requestedTokens = limit
            temperature = 0.2
        }

        MLX.Memory.clearCache()
        let prepared = try await container.prepare(input: input)
        let promptTokens = prepared.text.tokens.size
        let maxTokens = try budgetTokens(promptTokens: promptTokens, requested: requestedTokens)

        // Qwen3's published sampling settings for each mode.
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            kvBits: Self.kvBits,
            temperature: temperature,
            topP: thinking ? 0.95 : 0.8,
            topK: 20,
            prefillStepSize: Self.prefillStepSize
        )

        // Whether the chat template already opened a think block at the end
        // of the prompt, in which case the output starts as reasoning.
        let promptTail = prepared.text.tokens.asArray(Int32.self).suffix(8).map { Int($0) }
        let startsInReasoning = await container.perform { (context: ModelContext) in
            context.tokenizer.decode(tokenIds: promptTail, skipSpecialTokens: false)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix("<think>")

        var splitter = ThinkSplitter(startsInReasoning: startsInReasoning)
        var generated = 0
        func emit(_ pieces: [ThinkSplitter.Piece]) {
            for piece in pieces where !piece.text.isEmpty {
                onEvent(piece.isReasoning ? .reasoning(piece.text) : .text(piece.text))
            }
        }

        // For Settings > Power: which model ran, for how long, and what the
        // battery did meanwhile.
        let battery = await UsageStore.shared.reading()
        let startedAt = Date()
        let modelName = loadedName

        // Assigning any value resets the peak counter.
        MLX.Memory.peakMemory = 0
        Diagnostics.begin("generate", "prompt=\(promptTokens) max=\(maxTokens) "
            + "think=\(thinking) tools=\(tools.count) "
            + "active=\(Diagnostics.megabytes(MLX.Memory.activeMemory))MB "
            + "avail=\(Diagnostics.availableMB)MB")
        defer {
            let chunks = generated
            let seconds = Date().timeIntervalSince(startedAt)
            Task { @MainActor in
                UsageStore.shared.record(model: modelName, promptTokens: promptTokens,
                                         generatedTokens: chunks, seconds: seconds, start: battery)
            }
            Diagnostics.end("generate", "chunks=\(generated) "
                + "cancelled=\(Task.isCancelled) "
                + "peak=\(Diagnostics.megabytes(MLX.Memory.peakMemory))MB "
                + "avail=\(Diagnostics.availableMB)MB")
        }

        do {
            let stream = try await container.generate(input: prepared, parameters: parameters)
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .chunk(let text):
                    generated += 1
                    emit(splitter.feed(text))
                case .toolCall(let call):
                    emit(splitter.flush())
                    onEvent(.toolCall(
                        id: call.id,
                        name: call.function.name,
                        arguments: Self.convert(call.function.arguments)
                    ))
                case .info(let info):
                    emit(splitter.flush())
                    onEvent(.finished(tokensPerSecond: info.tokensPerSecond))
                default:
                    break
                }
            }
            emit(splitter.flush())
        } catch {
            Diagnostics.log("generate.error \(error.localizedDescription)")
            throw RunnerError.generationFailed(error.localizedDescription)
        }
        MLX.Memory.clearCache()
    }

    /// How many tokens this turn may generate without running out of memory.
    private func budgetTokens(promptTokens: Int, requested: Int) throws -> Int {
        guard let headroom = Self.availableMemory() else { return requested }

        let usable = headroom - Self.reserveBytes
        let promptCost = promptTokens * kvBytesPerToken + Self.prefillWorkspaceBytes
        let answerTokens = (usable - promptCost) / max(kvBytesPerToken, 1)

        guard answerTokens >= Self.minimumAnswerTokens else {
            throw RunnerError.insufficientMemory(
                "Not enough memory left to answer. Start a new conversation to clear the history, "
                    + "close other apps, or turn off Think for shorter answers.")
        }

        // Keep MLX under the real ceiling: when it reaches this it frees cached
        // buffers and waits, rather than allocating into a termination.
        MLX.Memory.memoryLimit = MLX.Memory.activeMemory + max(usable, 0)
        return min(requested, answerTokens)
    }

    // MARK: - Thinking

    /// Separates `<think>…</think>` output from the answer while it streams.
    /// Tags can be split across chunks, so any trailing text that could be the
    /// start of a tag is held back until the next chunk decides it.
    ///
    /// Qwen3 writes the opening tag itself. Qwen3.5's chat template writes it
    /// into the prompt instead, so the output begins mid-reasoning and only
    /// the closing tag appears; `startsInReasoning` covers that case.
    struct ThinkSplitter {
        struct Piece {
            let isReasoning: Bool
            let text: String
        }

        private var buffer = ""
        private var inThink: Bool
        private static let open = "<think>"
        private static let close = "</think>"

        init(startsInReasoning: Bool = false) {
            inThink = startsInReasoning
        }

        mutating func feed(_ chunk: String) -> [Piece] {
            buffer += chunk
            var pieces: [Piece] = []
            while true {
                // A redundant opening tag inside reasoning is dropped.
                if inThink, let stray = buffer.range(of: Self.open) {
                    buffer.removeSubrange(stray)
                }
                let tag = inThink ? Self.close : Self.open
                if let range = buffer.range(of: tag) {
                    pieces.append(Piece(isReasoning: inThink, text: String(buffer[..<range.lowerBound])))
                    buffer = String(buffer[range.upperBound...])
                    inThink.toggle()
                    continue
                }
                let keep = Self.partialTagSuffix(buffer, tag: tag)
                let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
                pieces.append(Piece(isReasoning: inThink, text: String(buffer[..<cut])))
                buffer = String(buffer[cut...])
                return pieces
            }
        }

        mutating func flush() -> [Piece] {
            defer { buffer = "" }
            return [Piece(isReasoning: inThink, text: buffer)]
        }

        /// Length of the longest suffix of `text` that is a prefix of `tag`.
        private static func partialTagSuffix(_ text: String, tag: String) -> Int {
            let maxLength = min(text.count, tag.count - 1)
            guard maxLength > 0 else { return 0 }
            for length in stride(from: maxLength, through: 1, by: -1)
            where tag.hasPrefix(String(text.suffix(length))) {
                return length
            }
            return 0
        }
    }

    // MARK: - Message bridging

    /// The app's own message type, so nothing outside this file imports MLX.
    ///
    /// An assistant turn that requested tools carries those calls, and each
    /// tool result carries the id of the call it answers, so the model always
    /// sees which call a result belongs to.
    struct Message: Codable {
        enum Role: String, Codable { case system, user, assistant, tool }

        struct Call: Codable {
            let id: String
            let name: String
            let arguments: ArgumentValue
        }

        let role: Role
        let content: String
        var calls: [Call] = []
        var callID: String?

        static func system(_ text: String) -> Message { Message(role: .system, content: text) }
        static func user(_ text: String) -> Message { Message(role: .user, content: text) }
        static func assistant(_ text: String, calls: [Call] = []) -> Message {
            Message(role: .assistant, content: text, calls: calls)
        }
        static func tool(_ text: String, callID: String) -> Message {
            Message(role: .tool, content: text, callID: callID)
        }

        var asChatMessage: MLXLMCommon.Chat.Message {
            switch role {
            case .system:
                return .system(content)
            case .user:
                return .user(content)
            case .assistant:
                guard !calls.isEmpty else { return .assistant(content) }
                let toolCalls = calls.map { call -> MLXLMCommon.ToolCall in
                    let arguments: [String: MLXLMCommon.JSONValue] =
                        ModelRunner.frameworkArguments(call.arguments)
                    return MLXLMCommon.ToolCall(
                        function: MLXLMCommon.ToolCall.Function(name: call.name, arguments: arguments),
                        id: call.id
                    )
                }
                return .assistant(content, toolCalls: toolCalls)
            case .tool:
                return .tool(content, id: callID)
            }
        }
    }

    fileprivate static func frameworkArguments(_ value: ArgumentValue) -> [String: MLXLMCommon.JSONValue] {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: data)
        else { return [:] }
        return decoded
    }

    /// MLX's `JSONValue` to ours, by a JSON round trip; both types are Codable.
    private static func convert(_ arguments: [String: MLXLMCommon.JSONValue]) -> ArgumentValue {
        guard let data = try? JSONEncoder().encode(arguments),
              let value = try? JSONDecoder().decode(ArgumentValue.self, from: data)
        else { return .object([:]) }
        return value
    }
}
