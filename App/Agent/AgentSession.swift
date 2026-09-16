import Foundation
import Observation

/// One line in the visible transcript.
struct TranscriptEntry: Identifiable {
    enum Kind {
        case user
        case assistant
        /// A tool ran; shown as a compact chip rather than a chat bubble.
        case tool
        case error
    }

    let id = UUID()
    let kind: Kind
    var text: String
    /// Set for tool entries so the UI can show the right glyph.
    var toolOutcome: Outcome?
    var isStreaming: Bool = false

    enum Outcome {
        case done
        case awaitingUser
        case failed
    }
}

/// Drives one conversation: prompt, tool calls, tool results, reply.
///
/// The loop is deliberately bounded and sequential. A phone running an 8B
/// model at a few tokens per second cannot afford speculative or parallel tool
/// execution, and the tools here have real side effects — sending a message
/// twice because two calls raced is not a recoverable error. So: one tool at a
/// time, a hard iteration cap, and every result fed back before the next
/// decision.
@MainActor
@Observable
final class AgentSession {

    private(set) var transcript: [TranscriptEntry] = []
    private(set) var isWorking = false
    /// Tokens per second from the last completed turn, shown in the model picker.
    private(set) var lastThroughput: Double?

    /// Model-visible history, which is not the same as the transcript: it
    /// carries tool results and omits UI-only entries.
    private var history: [ModelRunner.Message] = []

    private let runner: ModelRunner
    private let registry: ToolRegistry
    private var task: Task<Void, Never>?

    /// Cap on tool calls per user request.
    ///
    /// Without a cap a model that misreads a tool result will call the same
    /// tool forever. Six is enough for a genuinely multi-step request
    /// (get time, find contact, check calendar, create event, then reply)
    /// while bounding the worst case to something the user can wait out.
    private let maxToolIterations = 6

    /// Turns of history kept before trimming.
    ///
    /// Each tool result can be several hundred tokens, and on-device context is
    /// the scarcest resource here — a long history slows every subsequent turn
    /// because the whole prompt is reprocessed.
    private let maxHistoryMessages = 24

    init(runner: ModelRunner, registry: ToolRegistry) {
        self.runner = runner
        self.registry = registry
    }

    // MARK: - Public entry points

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }

        transcript.append(TranscriptEntry(kind: .user, text: trimmed))
        history.append(.user(trimmed))
        isWorking = true

        task = Task { [weak self] in
            await self?.runTurn()
            self?.isWorking = false
        }
    }

    /// Stops the current turn.
    ///
    /// Note what this can and cannot do: it stops generation and prevents
    /// further tool calls, but a tool already in flight completes. A calendar
    /// event half-written is worse than one written, so cancellation is
    /// checked between tools rather than inside them.
    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
        if let index = transcript.indices.last, transcript[index].isStreaming {
            transcript[index].isStreaming = false
            if transcript[index].text.isEmpty {
                transcript[index].text = "Stopped."
            }
        }
    }

    func clear() {
        cancel()
        transcript.removeAll()
        history.removeAll()
        lastThroughput = nil
    }

    // MARK: - The loop

    private func runTurn() async {
        let tools = registry.specs
        let modelName = await runner.loadedName
        let systemPrompt = SystemPrompt.build(tools: tools, modelName: modelName)

        for iteration in 0..<maxToolIterations {
            if Task.isCancelled { return }

            var messages: [ModelRunner.Message] = [.system(systemPrompt)]
            messages.append(contentsOf: trimmedHistory())

            // A streaming placeholder the UI fills in as chunks arrive.
            let entryIndex = transcript.count
            transcript.append(TranscriptEntry(kind: .assistant, text: "", isStreaming: true))

            var replyText = ""
            var pendingCalls: [(name: String, arguments: ArgumentValue)] = []

            do {
                // This loop body runs on the main actor, so the transcript can
                // be mutated directly and the accumulators above can be plain
                // locals.
                for try await event in runner.stream(messages: messages, tools: tools) {
                    switch event {
                    case .text(let chunk):
                        replyText += chunk
                        if transcript.indices.contains(entryIndex) {
                            transcript[entryIndex].text = replyText
                        }
                    case .toolCall(let name, let arguments):
                        pendingCalls.append((name, arguments))
                    case .finished(let throughput):
                        lastThroughput = throughput
                    }
                }
            } catch {
                finishStreaming(at: entryIndex, text: replyText)
                transcript.append(TranscriptEntry(
                    kind: .error,
                    text: error.localizedDescription
                ))
                return
            }

            finishStreaming(at: entryIndex, text: replyText)

            if !replyText.isEmpty {
                history.append(.assistant(replyText))
            }

            // No tools requested: the turn is the model's answer, and we stop.
            guard !pendingCalls.isEmpty else {
                if replyText.isEmpty {
                    // An empty reply with no tool call is a dead turn. Saying
                    // so is better than leaving a blank bubble.
                    transcript[entryIndex].text =
                        "I did not produce a reply. Try rephrasing the request."
                }
                return
            }

            // Drop the empty placeholder when the model went straight to a tool.
            if replyText.isEmpty, transcript.indices.contains(entryIndex) {
                transcript.remove(at: entryIndex)
            }

            for call in pendingCalls {
                if Task.isCancelled { return }
                await execute(call.name, arguments: call.arguments)
            }

            // On the last permitted iteration, tell the model to stop calling
            // tools and summarise. Without this the turn ends silently after
            // the cap and the user sees tool chips but no reply.
            if iteration == maxToolIterations - 1 {
                history.append(.user(
                    "You have reached the tool limit for this request. Do not call any more "
                        + "tools. Reply now in one or two sentences describing what you did."
                ))
                await summarise(systemPrompt: systemPrompt)
                return
            }
        }
    }

    private func execute(_ name: String, arguments: ArgumentValue) async {
        let index = transcript.count
        let label = registry.spec(named: name)?.name ?? name
        transcript.append(TranscriptEntry(kind: .tool, text: "Running \(label)…"))

        let outcome = await registry.run(name, arguments: arguments)

        if transcript.indices.contains(index) {
            transcript[index].text = outcome.summary
            transcript[index].toolOutcome = outcome.ok
                ? (outcome.awaitingUserConfirmation ? .awaitingUser : .done)
                : .failed
        }

        history.append(.tool(outcome.modelResponseJSON, name: name))
    }

    /// One final generation with tools withheld, to produce a closing reply.
    private func summarise(systemPrompt: String) async {
        var messages: [ModelRunner.Message] = [.system(systemPrompt)]
        messages.append(contentsOf: trimmedHistory())

        let entryIndex = transcript.count
        transcript.append(TranscriptEntry(kind: .assistant, text: "", isStreaming: true))
        var replyText = ""

        do {
            for try await event in runner.stream(messages: messages, tools: []) {
                if case .text(let chunk) = event {
                    replyText += chunk
                    if transcript.indices.contains(entryIndex) {
                        transcript[entryIndex].text = replyText
                    }
                }
            }
        } catch {
            // The tools already ran; failing to narrate them is not worth an
            // error bubble on top of the tool chips the user can already see.
        }

        finishStreaming(at: entryIndex, text: replyText)
        if replyText.isEmpty, transcript.indices.contains(entryIndex) {
            transcript.remove(at: entryIndex)
        } else if !replyText.isEmpty {
            history.append(.assistant(replyText))
        }
    }

    private func finishStreaming(at index: Int, text: String) {
        guard transcript.indices.contains(index) else { return }
        transcript[index].isStreaming = false
        transcript[index].text = text
    }

    /// Keeps history bounded, preserving the oldest user message.
    ///
    /// Trimming from the front can orphan a tool result whose preceding
    /// assistant turn was dropped, which some chat templates reject. So the
    /// window is walked backwards and cut at a user message.
    private func trimmedHistory() -> [ModelRunner.Message] {
        guard history.count > maxHistoryMessages else { return history }

        let tail = history.suffix(maxHistoryMessages)
        if let offset = tail.firstIndex(where: { $0.role == .user }) {
            var window = Array(tail[offset...])
            window.insert(.system(SystemPrompt.compactReminder), at: 0)
            return window
        }
        return Array(tail)
    }
}
