import Foundation
import MLXLLM
import MLXLMCommon
// HubClient lives here. Required even for a purely local load, because the
// factory signature takes one; it simply never reaches the network when the
// configuration points at a directory.
import MLXHuggingFace

#if canImport(MLX)
import MLX
#endif

/// The only file that touches MLX.
///
/// Everything above this layer speaks in `RunnerEvent` and `ArgumentValue`, so
/// the agent loop, the tools and the UI carry no dependency on the inference
/// framework. That matters for two reasons: MLX's API moves quickly, and this
/// project is authored on Windows where none of it can be compiled. Keeping
/// the surface area to one file means an API change is one file to fix rather
/// than a hunt through the app.
///
/// Framework-side names deliberately avoided in the rest of the app because
/// they collide with ours: MLXLMCommon defines both `ToolSpec` (which is just
/// `[String: any Sendable]`) and `JSONValue`. Ours are `ToolDescriptor` and
/// `ArgumentValue` for that reason.
actor ModelRunner {

    /// What the agent loop consumes. No MLX types cross this boundary.
    enum RunnerEvent {
        case text(String)
        case toolCall(name: String, arguments: ArgumentValue)
        case finished(tokensPerSecond: Double?)
    }

    enum RunnerError: LocalizedError {
        case noModelLoaded
        case loadFailed(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noModelLoaded:
                return "No model is loaded. Pick one from the model list first."
            case .loadFailed(let why):
                return "The model could not be loaded: \(why)"
            case .generationFailed(let why):
                return "Generation failed: \(why)"
            }
        }
    }

    private var container: ModelContainer?
    private var loadedDirectory: String?

    /// Human-readable name of what is loaded, used in the system prompt so the
    /// model can answer "what are you" correctly.
    private(set) var loadedName: String = "a local model"

    var isLoaded: Bool { container != nil }

    // MARK: - Loading

    /// Loads a model from a local directory.
    ///
    /// `ModelConfiguration(directory:)` points the factory at files already on
    /// disk, so nothing is fetched. A `HubClient` is still required by the
    /// factory signature but goes unused for a local load — which is the point:
    /// this app must work with the network off.
    func load(directory: URL, displayName: String, adapterDirectory: URL? = nil) async throws {
        let signature = directory.path + "|" + (adapterDirectory?.path ?? "")
        if loadedDirectory == signature, container != nil { return }

        // Release the previous model first. Two multi-gigabyte models resident
        // at once is an immediate jetsam kill on a phone.
        container = nil
        loadedDirectory = nil

        configureMemoryLimits()

        let configuration = ModelConfiguration(directory: directory)
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: configuration
            )
            if let adapterDirectory {
                try await Self.applyAdapter(at: adapterDirectory, to: loaded)
            }
            container = loaded
            loadedDirectory = signature
            loadedName = displayName
        } catch {
            container = nil
            throw RunnerError.loadFailed(error.localizedDescription)
        }
    }

    /// Layers a LoRA adapter onto the loaded model.
    ///
    /// Adapters are applied after the base model is resident, which is what
    /// makes the cheap fine-tuning path viable: a ~100MB adapter folder rather
    /// than a second 4.6GB copy of the weights. See
    /// training/convert_adapter.py for producing one in this format.
    ///
    /// Failing to apply an adapter throws rather than degrading silently. A
    /// model that loads but ignores its adapter looks exactly like a
    /// fine-tune that did not work, and that is a miserable thing to debug.
    private static func applyAdapter(at directory: URL, to container: ModelContainer) async throws {
        try await container.perform { context in
            let adapter = try LoRAContainer.from(directory: directory)
            try adapter.load(into: context.model)
        }
    }

    func unload() {
        container = nil
        loadedDirectory = nil
        loadedName = "a local model"
    }

    /// Caps MLX's buffer cache.
    ///
    /// MLX keeps freed GPU buffers in a cache to avoid reallocation. That is
    /// the right default on a Mac and the wrong one on a phone holding a 4.6GB
    /// model, where the cache is what pushes the process over the jetsam limit.
    /// A small cap trades a little throughput for not being killed.
    ///
    /// For finer control, MLXLMCommon ships wired-memory policies
    /// (`WiredSumPolicy`, `WiredMemoryUtils.tune`) that can be passed per
    /// generation as a `wiredMemoryTicket:`. Worth adopting once there are real
    /// measurements from the device; this cap is the safe starting point.
    private func configureMemoryLimits() {
        #if canImport(MLX)
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
        #endif
    }

    // MARK: - Generation

    /// Streams one assistant turn as an async sequence.
    ///
    /// A stream rather than a callback, for two reasons. A `@Sendable` callback
    /// cannot capture and mutate the caller's local accumulators, which forces
    /// either shared mutable state or a main-actor hop per token — and at a few
    /// tokens per second on a phone, one `Task` allocation per token is waste
    /// for no benefit. Consuming a stream on the main actor lets the caller use
    /// ordinary local variables and keeps cancellation tied to the sequence.
    /// `nonisolated` so callers can write `for try await event in
    /// runner.stream(...)` directly. An actor-isolated non-async method would
    /// need `await` on the call expression itself, which reads badly inside a
    /// for-await and is easy to forget. Building the stream touches no actor
    /// state; the isolated work happens inside the Task below.
    nonisolated func stream(
        messages: [Message],
        tools: [ToolDescriptor],
        maxTokens: Int = 640
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    ) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Ties cancellation to the consumer: breaking out of the for-await
            // loop stops generation instead of leaving it running unobserved.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one turn, reporting events through a callback.
    ///
    /// `enable_thinking: false` goes through `additionalContext`, which is how
    /// the chat template's `enable_thinking` flag is set. Qwen3 is a hybrid
    /// reasoning model that emits long `<think>` blocks by default; for "add
    /// this to my calendar" that is pure latency on a device already running
    /// at a few tokens per second. The training data is rendered with the same
    /// flag, so the prompt shape matches between training and inference.
    private func generate(
        messages: [Message],
        tools: [ToolDescriptor],
        maxTokens: Int,
        onEvent: @Sendable @escaping (RunnerEvent) -> Void
    ) async throws {
        guard let container else { throw RunnerError.noModelLoaded }

        let chat = messages.map { $0.asChatMessage }
        let input = UserInput(
            chat: chat,
            tools: tools.map(\.functionSchema),
            additionalContext: ["enable_thinking": false]
        )

        // Qwen3's published non-thinking sampling settings. Temperature above
        // ~0.8 measurably increases malformed tool calls at 4-bit.
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.7,
            topP: 0.8
        )

        do {
            let prepared = try await container.prepare(input: input)
            let stream = try await container.generate(input: prepared, parameters: parameters)

            for await event in stream {
                switch event {
                case .chunk(let text):
                    onEvent(.text(text))
                case .toolCall(let call):
                    onEvent(.toolCall(
                        name: call.function.name,
                        arguments: Self.convert(call.function.arguments)
                    ))
                case .info(let info):
                    onEvent(.finished(tokensPerSecond: info.tokensPerSecond))
                // The Generation enum gains cases (reasoning events, for
                // example). An exhaustive switch would stop compiling on a
                // dependency bump, so unknown events are ignored.
                default:
                    break
                }
            }
        } catch {
            throw RunnerError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Message bridging

    /// The app's own message type, so nothing outside this file imports MLX.
    struct Message {
        enum Role { case system, user, assistant, tool }

        let role: Role
        let content: String
        /// Tool name, for tool-result messages.
        var toolName: String?

        static func system(_ text: String) -> Message { Message(role: .system, content: text) }
        static func user(_ text: String) -> Message { Message(role: .user, content: text) }
        static func assistant(_ text: String) -> Message { Message(role: .assistant, content: text) }
        static func tool(_ text: String, name: String) -> Message {
            Message(role: .tool, content: text, toolName: name)
        }

        var asChatMessage: Chat.Message {
            switch role {
            case .system: return .system(content)
            case .user: return .user(content)
            case .assistant: return .assistant(content)
            case .tool: return .tool(content, name: toolName)
            }
        }
    }

    /// Bridges MLX's `JSONValue` to ours.
    ///
    /// `sendableValue` erases to `any Sendable`, so the concrete type is
    /// recovered by casting. Numbers arrive as several widths depending on how
    /// the model wrote them, hence the ladder.
    private static func convert(_ arguments: [String: MLXLMCommon.JSONValue]) -> ArgumentValue {
        var object: [String: ArgumentValue] = [:]
        for (key, value) in arguments {
            object[key] = convert(value)
        }
        return .object(object)
    }

    private static func convert(_ value: MLXLMCommon.JSONValue) -> ArgumentValue {
        let raw = value.sendableValue
        if let v = raw as? String { return .string(v) }
        if let v = raw as? Bool { return .bool(v) }
        if let v = raw as? Int { return .number(Double(v)) }
        if let v = raw as? Double { return .number(v) }
        if let v = raw as? Float { return .number(Double(v)) }
        if let v = raw as? [Any] {
            return .array(v.compactMap { element in
                (element as? Sendable).map { wrap($0) }
            })
        }
        if let v = raw as? [String: Any] {
            var object: [String: ArgumentValue] = [:]
            for (key, element) in v {
                if let sendable = element as? Sendable { object[key] = wrap(sendable) }
            }
            return .object(object)
        }
        return .null
    }

    private static func wrap(_ raw: any Sendable) -> ArgumentValue {
        if let v = raw as? String { return .string(v) }
        if let v = raw as? Bool { return .bool(v) }
        if let v = raw as? Int { return .number(Double(v)) }
        if let v = raw as? Double { return .number(v) }
        return .null
    }
}
