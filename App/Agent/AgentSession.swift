import Foundation
import Observation
import UIKit

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
    /// Qwen3 thinking for assistant entries, shown folded away.
    var reasoning: String = ""

    enum Outcome {
        case done
        /// Staged in a system sheet; the user must tap send.
        case awaitingUser
        /// Another app took over; the result is unobservable.
        case handedOff
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
    /// True only while the model is producing tokens, which is the one time
    /// leaving the app is dangerous (see `leavingForeground`).
    private(set) var isGenerating = false
    /// Tokens per second from the last completed turn, shown in the model picker.
    private(set) var lastThroughput: Double?

    /// Qwen3's reasoning mode. Much better at maths, logic and code; slower,
    /// and it uses more memory per turn.
    var thinkingEnabled: Bool = true

    /// Model-visible history, which is not the same as the transcript: it
    /// carries tool results and omits UI-only entries.
    private var history: [ModelRunner.Message] = []

    private let runner: ModelRunner
    private let registry: ToolRegistry
    private var task: Task<Void, Never>?
    /// Source of tool-call ids when the framework does not supply one.
    private var callCounter = 0
    /// What the user asked this turn, and what the model said just before.
    /// Tool policy checks these, not the model's own reading of them.
    private var currentRequest = ""
    private var previousReply = ""

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

        previousReply = history.last(where: { $0.role == .assistant })?.content ?? ""
        currentRequest = trimmed
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

    /// Called as soon as Conduit stops being the active app.
    ///
    /// iOS does not let background apps use the GPU, and MLX aborts the whole
    /// process when a GPU command is refused. So a generation in progress is
    /// stopped here, at the inactive step, which comes before the background
    /// step and leaves time for the last token to finish. A turn that is only
    /// waiting for the user to come back from another app is left alone.
    func leavingForeground() {
        Diagnostics.log("app.inactive generating=\(isGenerating)")
        guard isGenerating else { return }
        cancel()
        transcript.append(TranscriptEntry(
            kind: .error,
            text: "Stopped because you switched away from Conduit. iOS does not let apps "
                + "use the GPU in the background. Ask again to continue."
        ))
    }

    /// Shows that the previous run was killed in the middle of some work.
    func noteInterruptedWork(_ marker: String) {
        let phase = marker.split(separator: " ").first.map(String.init) ?? ""
        let what = phase == "load" ? "loading the model" : "answering"
        transcript.append(TranscriptEntry(
            kind: .error,
            text: "Conduit was closed while \(what) last time, most likely because iOS ran "
                + "out of memory for it. Try turning off Think, a shorter question, a new "
                + "conversation, or a smaller model. Details are in conduit-log.txt in the "
                + "Files app, under On My iPhone > Conduit."
        ))
    }

    func clear() {
        cancel()
        transcript.removeAll()
        history.removeAll()
        callCounter = 0
        lastThroughput = nil
    }

    // MARK: - The loop

    private func runTurn() async {
        let tools = registry.specs
        let systemPrompt = SystemPrompt.build(tools: tools)

        for iteration in 0..<maxToolIterations {
            await waitUntilForeground()
            if Task.isCancelled { return }

            var messages: [ModelRunner.Message] = [.system(systemPrompt)]
            messages.append(contentsOf: trimmedHistory())

            // A streaming placeholder the UI fills in as chunks arrive.
            let entryIndex = transcript.count
            transcript.append(TranscriptEntry(kind: .assistant, text: "", isStreaming: true))

            var replyText = ""
            var pendingCalls: [ModelRunner.Message.Call] = []

            isGenerating = true
            do {
                // This loop body runs on the main actor, so the transcript can
                // be mutated directly and the accumulators above can be plain
                // locals.
                for try await event in runner.stream(
                    messages: messages, tools: tools, thinking: thinkingEnabled
                ) {
                    switch event {
                    case .text(let chunk):
                        replyText += chunk
                        if transcript.indices.contains(entryIndex) {
                            transcript[entryIndex].text = replyText
                        }
                    case .reasoning(let chunk):
                        if transcript.indices.contains(entryIndex) {
                            transcript[entryIndex].reasoning += chunk
                        }
                    case .toolCall(let id, let name, let arguments):
                        // The framework may not assign ids. Ours only need to
                        // be unique within the history, so a counter is enough.
                        callCounter += 1
                        pendingCalls.append(ModelRunner.Message.Call(
                            id: id ?? "call_\(callCounter)",
                            name: name,
                            arguments: arguments
                        ))
                    case .finished(let throughput):
                        lastThroughput = throughput
                    }
                }
            } catch {
                isGenerating = false
                finishStreaming(at: entryIndex, text: replyText)
                transcript.append(TranscriptEntry(
                    kind: .error,
                    text: error.localizedDescription
                ))
                return
            }
            isGenerating = false

            if Task.isCancelled {
                // cancel() has already closed the bubble. Keep any partial
                // answer, but run none of the tools it asked for.
                if !replyText.isEmpty {
                    finishStreaming(at: entryIndex, text: replyText)
                    history.append(.assistant(replyText))
                }
                return
            }

            finishStreaming(at: entryIndex, text: replyText)

            // The assistant turn is recorded whenever it said something OR
            // asked for tools. A tool-only turn has empty text, and dropping
            // it would leave the tool results below with no call on record.
            if !replyText.isEmpty || !pendingCalls.isEmpty {
                history.append(.assistant(replyText, calls: pendingCalls))
            }

            // No tools requested: the turn is the model's answer, and we stop.
            guard !pendingCalls.isEmpty else {
                if replyText.isEmpty, transcript.indices.contains(entryIndex) {
                    // An empty reply with no tool call is a dead turn. Saying
                    // so is better than leaving a blank bubble.
                    transcript[entryIndex].text = transcript[entryIndex].reasoning.isEmpty
                        ? "I did not produce a reply. Try rephrasing the request."
                        : "I ran out of room while thinking. Try a narrower question, "
                            + "or turn off Think."
                }
                return
            }

            // Drop the empty placeholder when the model went straight to a tool,
            // unless it has reasoning worth keeping on screen.
            if replyText.isEmpty, transcript.indices.contains(entryIndex),
               transcript[entryIndex].reasoning.isEmpty {
                transcript.remove(at: entryIndex)
            }

            for call in pendingCalls {
                if Task.isCancelled { return }
                await execute(call)
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

    private func execute(_ call: ModelRunner.Message.Call) async {
        let name = call.name

        // Refused calls go back to the model only. The user asked a question,
        // not for a failed tool chip.
        if let refusal = ToolPolicy.refusal(
            for: name, request: currentRequest, previousReply: previousReply
        ) {
            Diagnostics.log("tool.blocked \(name)")
            history.append(.tool(refusal.modelResponseJSON, callID: call.id))
            return
        }
        Diagnostics.log("tool.run \(name)")
        let index = transcript.count
        let label = registry.spec(named: name)?.name ?? name
        transcript.append(TranscriptEntry(kind: .tool, text: "Running \(label)…"))

        let outcome = await registry.run(name, arguments: call.arguments)

        if transcript.indices.contains(index) {
            transcript[index].text = outcome.summary
            if outcome.ok {
                switch outcome.completion {
                case .completed: transcript[index].toolOutcome = .done
                case .awaitingUser: transcript[index].toolOutcome = .awaitingUser
                case .handedOff: transcript[index].toolOutcome = .handedOff
                }
            } else {
                transcript[index].toolOutcome = .failed
            }
        }

        history.append(.tool(outcome.modelResponseJSON, callID: call.id))

        // The tool switched to another app. Give the switch a moment to
        // happen, then hold the turn until the user comes back.
        if outcome.ok, outcome.completion == .handedOff {
            try? await Task.sleep(for: .milliseconds(800))
            await waitUntilForeground()
        }
    }

    /// Returns once Conduit is the frontmost app, so the next generation never
    /// starts in the background, where iOS refuses GPU work.
    private func waitUntilForeground() async {
        while UIApplication.shared.applicationState != .active {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// One final generation with tools withheld, to produce a closing reply.
    private func summarise(systemPrompt: String) async {
        await waitUntilForeground()
        if Task.isCancelled { return }
        var messages: [ModelRunner.Message] = [.system(systemPrompt)]
        messages.append(contentsOf: trimmedHistory())

        let entryIndex = transcript.count
        transcript.append(TranscriptEntry(kind: .assistant, text: "", isStreaming: true))
        var replyText = ""

        isGenerating = true
        defer { isGenerating = false }
        do {
            for try await event in runner.stream(
                messages: messages, tools: [], thinking: false
            ) {
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

    /// Keeps history bounded.
    ///
    /// Trimming from the front can orphan a tool result whose preceding
    /// assistant turn was dropped, which some chat templates reject. So the
    /// window is walked backwards and cut at a user message. No second system
    /// message is added: the full prompt already leads every request.
    private func trimmedHistory() -> [ModelRunner.Message] {
        guard history.count > maxHistoryMessages else { return history }

        let tail = history.suffix(maxHistoryMessages)
        if let offset = tail.firstIndex(where: { $0.role == .user }) {
            return Array(tail[offset...])
        }
        return Array(tail)
    }
}
