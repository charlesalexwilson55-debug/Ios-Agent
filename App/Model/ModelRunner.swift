import Foundation
import MLX
import MLXLLM
import MLXLMCommon
// mlx-swift-lm 3.31.4 ships no concrete tokenizer loader. MLXHuggingFace
// provides the #huggingFaceTokenizerLoader() macro, and its expansion calls
// Tokenizers.AutoTokenizer directly — so `import Tokenizers` (swift-transformers)
// is required here for the expanded code to compile, even though nothing in
// this file names that module explicitly. Remove it and the build fails inside
// macro-generated code, which is a confusing place to be.
import MLXHuggingFace
import Tokenizers

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
        /// `id` is whatever the framework assigned, which may be nil; the
        /// agent loop assigns its own when it is.
        case toolCall(id: String?, name: String, arguments: ArgumentValue)
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
    /// Uses the local-directory overload of `loadModelContainer`, which takes
    /// a `URL` and a tokenizer loader and nothing else. The alternative —
    /// `LLMModelFactory.shared.loadContainer(from:using:configuration:)` with
    /// a `ModelConfiguration(directory:)` — needs a `Downloader` passed in for
    /// a load that will never touch the network. Taking the overload that
    /// cannot download is both simpler and a better match for the guarantee
    /// this app makes: it works with the network off.
    ///
    /// The tradeoff is no `ModelConfiguration`, so no place to force a
    /// `toolCallFormat` or extra EOS tokens. Qwen3's format is resolved from
    /// the model metadata and chat template, so that costs nothing here; a
    /// model needing an override would have to go back to the factory call.
    func load(directory: URL, displayName: String, adapterDirectory: URL? = nil) async throws {
        let signature = directory.path + "|" + (adapterDirectory?.path ?? "")
        if loadedDirectory == signature, container != nil { return }

        // Release the previous model first. Two multi-gigabyte models resident
        // at once is an immediate jetsam kill on a phone.
        container = nil
        loadedDirectory = nil

        configureMemoryLimits()

        do {
            let loaded = try await loadModelContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
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
    /// than a second 4.6GB copy of the weights.
    ///
    /// Two on-disk formats are accepted, told apart by `adapter_config.json`:
    ///
    /// - **PEFT** (what Unsloth and Hugging Face `peft` write, and what
    ///   training/train_lora.py produces) carries a `peft_type` key and an
    ///   `adapter_model.safetensors`. Loaded with `LoRAContainer.fromPEFT`,
    ///   which renames the keys and reorients the matrices itself — so an
    ///   adapter straight off the GPU box needs no conversion step.
    /// - **MLX-native** (what `mlx_lm.lora` writes) has `fine_tune_type` and
    ///   `adapters.safetensors`. Loaded with `LoRAContainer.from`.
    ///
    /// Failing to apply an adapter throws rather than degrading silently. A
    /// model that loads but ignores its adapter looks exactly like a
    /// fine-tune that did not work, and that is a miserable thing to debug.
    private static func applyAdapter(at directory: URL, to container: ModelContainer) async throws {
        let adapter: LoRAContainer = try isPEFTAdapter(directory)
            ? LoRAContainer.fromPEFT(directory: directory)
            : LoRAContainer.from(directory: directory)

        // The explicit parameter type selects the ModelContext overload of
        // perform; ModelContainer also has a two-argument
        // (LanguageModel, Tokenizer) overload.
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
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
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
        let schemas = tools.map(\.functionSchema)
        let input = UserInput(
            chat: chat,
            tools: schemas,
            additionalContext: ["enable_thinking": false]
        )

        // Qwen3's published non-thinking sampling settings. Temperature above
        // ~0.8 measurably increases malformed tool calls at 4-bit, and topK
        // defaults to 0 (disabled) here whereas Qwen recommends 20.
        //
        // Deliberately NOT setting maxKVSize, even though a bounded KV cache is
        // the obvious lever against the memory ceiling an 8B model runs into.
        // Bounding it engages a rotating cache, and if that evicts the head of
        // the prompt it takes the system prompt with it — which is precisely
        // where the "never claim you sent it" rule lives. Losing that silently,
        // mid-conversation, is a far worse failure than being slow. Context is
        // bounded in AgentSession.trimmedHistory() instead, where the system
        // prompt is re-inserted by construction.
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.7,
            topP: 0.8,
            topK: 20
        )

        do {
            // Tools reach the model once, through UserInput: the chat template
            // renders them into the system turn. In 3.31.4, generate() has no
            // tools: parameter of its own (that exists only on main); the
            // tool-call processor recognises calls from the format resolved at
            // load time.
            let prepared = try await container.prepare(input: input)
            let stream = try await container.generate(input: prepared, parameters: parameters)

            for await event in stream {
                switch event {
                case .chunk(let text):
                    onEvent(.text(text))
                case .toolCall(let call):
                    onEvent(.toolCall(
                        id: call.id,
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
    ///
    /// An assistant turn that requested tools carries those calls, and each
    /// tool result carries the id of the call it answers. Both matter: without
    /// the calls, the history shows the model a tool result it has no record
    /// of asking for, and on the next step it tends to call the same tool
    /// again. The training data is held to the same rule by
    /// training/validate_dataset.py, so the prompt the model sees at runtime
    /// matches the shape it was trained on.
    struct Message {
        enum Role { case system, user, assistant, tool }

        struct Call {
            let id: String
            let name: String
            let arguments: ArgumentValue
        }

        let role: Role
        let content: String
        /// For assistant turns: the tools this turn asked for.
        var calls: [Call] = []
        /// For tool turns: the id of the call this result answers.
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

    /// The reverse of `convert`: our arguments back into the framework's type,
    /// for replaying a past tool call into the chat history. Same JSON
    /// round-trip, same reasoning.
    fileprivate static func frameworkArguments(_ value: ArgumentValue) -> [String: MLXLMCommon.JSONValue] {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Bridges MLX's `JSONValue` to ours by round-tripping through JSON.
    ///
    /// Both types are `Codable`, so this needs no knowledge of the framework's
    /// internal representation — no `sendableValue` accessor, no ladder of
    /// `as?` casts guessing which numeric width the model happened to emit.
    /// Encoding and decoding is a little more work at runtime than reading the
    /// value directly, but a tool call is a few hundred bytes a handful of
    /// times per turn, against generation measured in tokens per second. The
    /// robustness is free in practice, and it is one fewer thing to break when
    /// the dependency moves.
    private static func convert(_ arguments: [String: MLXLMCommon.JSONValue]) -> ArgumentValue {
        guard let data = try? JSONEncoder().encode(arguments),
              let value = try? JSONDecoder().decode(ArgumentValue.self, from: data)
        else {
            // An unparseable argument set is reported as empty rather than
            // dropped: each tool then names the specific field it needed, and
            // the model gets an actionable retry instead of silence.
            return .object([:])
        }
        return value
    }
}
