import Foundation
import Observation
import UIKit

/// One line in the visible transcript.
struct TranscriptEntry: Identifiable, Codable {
    enum Kind: String, Codable {
        case user
        case assistant
        /// A tool ran; shown as a compact chip rather than a chat bubble.
        case tool
        /// A long task shown as steps, such as research.
        case activity
        case error
    }

    var id = UUID()
    let kind: Kind
    var text: String
    /// Set for tool entries so the UI can show the right glyph.
    var toolOutcome: Outcome?
    var isStreaming: Bool = false
    /// Qwen3 thinking for assistant entries, shown folded away.
    var reasoning: String = ""
    /// The steps of a long task, for `.activity` entries.
    var activity: ActivityLog?
    /// Pictures shown with the entry, from `ImageStore`.
    var imageIDs: [UUID] = []
    /// Source choices are kept out of the model's history until selected.
    var researchCandidates: [ResearchCandidate] = []
    var researchRequest: String?

    enum Outcome: String, Codable {
        case done
        /// Staged in a system sheet; the user must tap send.
        case awaitingUser
        /// Another app took over; the result is unobservable.
        case handedOff
        case failed
    }

    init(id: UUID = UUID(), kind: Kind, text: String, toolOutcome: Outcome? = nil,
         isStreaming: Bool = false, reasoning: String = "", activity: ActivityLog? = nil,
         imageIDs: [UUID] = [], researchCandidates: [ResearchCandidate] = [], researchRequest: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolOutcome = toolOutcome
        self.isStreaming = isStreaming
        self.reasoning = reasoning
        self.activity = activity
        self.imageIDs = imageIDs
        self.researchCandidates = researchCandidates
        self.researchRequest = researchRequest
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, toolOutcome, isStreaming, reasoning, activity, imageIDs, researchCandidates, researchRequest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        toolOutcome = try c.decodeIfPresent(Outcome.self, forKey: .toolOutcome)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        activity = try c.decodeIfPresent(ActivityLog.self, forKey: .activity)
        imageIDs = try c.decodeIfPresent([UUID].self, forKey: .imageIDs) ?? []
        researchCandidates = try c.decodeIfPresent([ResearchCandidate].self, forKey: .researchCandidates) ?? []
        researchRequest = try c.decodeIfPresent(String.self, forKey: .researchRequest)
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

    /// The user's globe switch. The web tools are offered only when this is
    /// on and the phone has a signal.
    var onlineEnabled: Bool = true

    /// Research mode, from the plus menu. While it is on, each request is
    /// followed across several web pages by `ResearchEngine` instead of
    /// going through the normal tool loop.
    var researchEnabled: Bool = false

    /// The image-reading model on the phone, if there is one.
    var visionModelDirectory: URL?
    /// Pictures attached to the message being answered.
    private var pendingImageIDs: [UUID] = []
    private var pendingResearchSelection: ResearchSelection?
    private var pendingResearchRun: ResearchRun?
    @ObservationIgnored private var researchOriginalModel: ModelRunner.Configuration?
    @ObservationIgnored private var unavailableResearchModels: Set<String> = []

    /// The saved chat this conversation is recorded under. A new one starts
    /// with each new conversation.
    private(set) var chatID = UUID()

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
    /// Per-turn tool state. `offeredTools` is what the model was shown;
    /// anything else it asks for is refused. `readWebContent` tightens
    /// `ToolPolicy` once untrusted web text is in the conversation, and
    /// stays set until the conversation is cleared, because that text stays
    /// in the history the model reads on later turns.
    private var offeredTools: Set<String> = []
    private var readWebContent = false
    private var usedPhoneTools = false
    /// Whether the previous turn was a phone task, so short follow-ups such
    /// as "yes, the second one" keep the phone tools.
    private var lastTurnUsedPhoneTools = false
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

    func submit(_ text: String, imageData: [Data] = [], researchSelection: ResearchSelection? = nil, resume: ResearchRun? = nil) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageData.isEmpty, !isWorking else { return }
        pendingResearchSelection = researchSelection
        pendingResearchRun = resume
        if trimmed.isEmpty { trimmed = "What's in this picture?" }
        pendingImageIDs = imageData.compactMap { ImageStore.shared.addPhoto($0, prompt: trimmed)?.id }

        previousReply = history.last(where: { $0.role == .assistant })?.content ?? ""
        currentRequest = trimmed
        var userEntry = TranscriptEntry(kind: .user, text: trimmed)
        userEntry.imageIDs = pendingImageIDs
        transcript.append(userEntry)
        history.append(.user(trimmed))
        isWorking = true

        task = Task { [weak self] in
            await self?.runTurn()
            self?.recordTurn(after: userEntry.id, request: trimmed)
            self?.isWorking = false
        }
    }

    func selectResearchCandidate(_ candidateID: String, in entryID: UUID) {
        guard !isWorking,
              let entry = transcript.first(where: { $0.id == entryID }),
              let request = entry.researchRequest,
              let candidate = entry.researchCandidates.first(where: { $0.id == candidateID }) else { return }
        submit("Research this profile: \(candidate.url.absoluteString)",
               researchSelection: ResearchSelection(request: request, candidate: candidate))
    }

    func resumeResearch(_ run: ResearchRun) {
        guard run.canResume, !isWorking else { return }
        submit(run.request, resume: run)
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
        // Research may still be draining GPU work and restoring the chat model.
        // Keep submit disabled until its task exits so another turn cannot load
        // weights concurrently with that restoration.
        if activeReporter == nil { isWorking = false }
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

    /// A line from the app itself, such as a model that could not be found.
    func note(_ text: String) {
        transcript.append(TranscriptEntry(kind: .error, text: text))
    }

    func clear() {
        guard !isWorking else { return }
        cancel()
        transcript.removeAll()
        history.removeAll()
        callCounter = 0
        lastThroughput = nil
        lastTurnUsedPhoneTools = false
        readWebContent = false
        pendingResearchSelection = nil
        chatID = UUID()
    }

    /// Restore saved exchange exactly and continue with its tool-aware history.
    func restore(_ chat: ChatRecord) {
        guard !isWorking else { return }
        clear()
        chatID = chat.id
        transcript = chat.transcript ?? chat.thoughts.flatMap { thought in
            var answer = TranscriptEntry(kind: .assistant, text: thought.answer)
            answer.reasoning = thought.reasoning
            return [TranscriptEntry(kind: .user, text: thought.request)]
                + thought.actions.map { TranscriptEntry(kind: .tool, text: $0) } + [answer]
        }
        history = chat.history ?? chat.thoughts.flatMap { [.user($0.request), .assistant($0.answer)] }
        for index in transcript.indices { transcript[index].isStreaming = false }
        readWebContent = history.contains(where: { $0.role == .tool })
        lastTurnUsedPhoneTools = readWebContent
        callCounter = history.reduce(0) { $0 + $1.calls.count }
    }

    /// Saves the finished exchange to the memory bank.
    private func recordTurn(after userEntryID: UUID, request: String) {
        guard let start = transcript.firstIndex(where: { $0.id == userEntryID }) else { return }
        let entries = transcript[(start + 1)...]
        guard let answer = entries.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text else {
            return
        }
        let reasoning = entries
            .filter { $0.kind == .assistant && !$0.reasoning.isEmpty }
            .map { $0.reasoning }
            .joined(separator: "\n\n")
        let actions = entries.flatMap { entry -> [String] in
            if entry.kind == .tool { return [entry.text] }
            guard let log = entry.activity else { return [] }
            return log.steps.map { step in
                [step.title, step.detail].compactMap { $0 }.joined(separator: ": ")
            }
        }
        let thought = ThoughtRecord(request: request, reasoning: String(reasoning.prefix(20_000)),
                                    actions: actions, answer: answer)
        ConversationStore.shared.record(chatID: chatID, thought: thought,
                                        transcript: transcript, history: history)
    }

    // MARK: - The loop

    private func runTurn() async {
        // Pictures go to the image model first; the chat model gets its
        // descriptions with the user's words.
        if !pendingImageIDs.isEmpty {
            let ids = pendingImageIDs
            pendingImageIDs = []
            guard let described = await readImages(ids) else { return }
            if let index = history.lastIndex(where: { $0.role == .user }) {
                history[index] = .user(currentRequest + "\n\n" + described)
            }
        } else if let picture = ImageIntent.prompt(from: currentRequest) {
            // Asked to make a picture: straight to the image model.
            await createImage(picture)
            return
        }

        let phoneTask = TaskRouter.looksLikePhoneTask(currentRequest)
        let selection = pendingResearchSelection
        pendingResearchSelection = nil
        let resume = pendingResearchRun
        pendingResearchRun = nil
        if researchEnabled || selection != nil || resume != nil {
            await runResearch(selection: selection, resume: resume)
            return
        }

        let mcp = MCPStore.shared
        let requestServers = mcp.servers(namedIn: currentRequest)
        let requestGoogle = GoogleTools.toolNames(for: currentRequest)
        var mode = TaskRouter.mode(for: currentRequest, previousTurnUsedPhoneTools: lastTurnUsedPhoneTools)
        // Naming a connected server or Google service is a request to use it.
        if !requestServers.isEmpty || !requestGoogle.isEmpty { mode = .task }
        let online = onlineEnabled && Connectivity.shared.isOnline

        let builtIn = registry.specs.filter {
            !$0.name.hasPrefix(MCPStore.toolPrefix) && !$0.name.hasPrefix(GoogleTools.prefix)
        }
        var tools = TaskRouter.tools(from: builtIn, mode: mode, online: online)
        if online {
            let outside = mcp.toolNames(for: requestServers)
                .union(requestGoogle)
            tools += registry.specs.filter { outside.contains($0.name) }
        }

        var systemPrompt = SystemPrompt.build(tools: tools, mode: mode)
        if let profile = ProfileStore.shared.promptSection {
            systemPrompt += "\n\n" + profile
        }
        // Earlier turns of this chat are still in the history unless it has
        // been trimmed, so they are only searched once it has.
        let notes = await Recall.notes(
            for: currentRequest,
            libraries: LibraryStore.shared.enabledCollections,
            excludingChat: history.count > maxHistoryMessages ? nil : ConversationStore.collection(for: chatID)
        )
        if !notes.isEmpty {
            systemPrompt += "\n\n" + notes.promptSection
            var chip = TranscriptEntry(kind: .tool, text: "Found \(notes.hits.count) note"
                + (notes.hits.count == 1 ? "" : "s") + ": " + notes.sourceNames.joined(separator: ", "))
            chip.toolOutcome = .done
            transcript.append(chip)
        }
        let thinking = thinkingEnabled
        let toolSteps = maxToolIterations
        offeredTools = Set(tools.map(\.name))
        usedPhoneTools = false
        defer { lastTurnUsedPhoneTools = usedPhoneTools }
        Diagnostics.log("turn mode=\(mode.rawValue) online=\(online) tools=\(tools.count) think=\(thinking)")

        for iteration in 0..<toolSteps {
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
                    messages: messages, tools: tools, thinking: thinking
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
            if iteration == toolSteps - 1 {
                history.append(.user(
                    "You have reached the tool limit for this request. Do not call any more "
                        + "tools. Reply now in one or two sentences describing what you did."
                ))
                await summarise(systemPrompt: systemPrompt)
                return
            }
        }
    }

    // MARK: - Research

    /// The research run in progress, so its steps can be stopped from the chat.
    @ObservationIgnored private var activeReporter: (entryID: UUID, reporter: ActivityReporter)?

    /// Stops a step or skips an item in a running activity.
    func cancelActivity(_ id: UUID, in entryID: UUID) {
        guard let active = activeReporter, active.entryID == entryID else { return }
        active.reporter.cancel(id)
    }

    /// Follows the request across the web with `ResearchEngine`, showing its
    /// steps as they happen, then writes up what was found.
    private func runResearch(selection: ResearchSelection? = nil, resume: ResearchRun? = nil) async {
        let request = resume?.request ?? selection?.request ?? currentRequest
        lastTurnUsedPhoneTools = false
        guard onlineEnabled, Connectivity.shared.isOnline else {
            let text = onlineEnabled
                ? "Research needs the internet, and there is no signal right now."
                : "Research needs the internet. Turn on Online in the plus menu, then ask again."
            transcript.append(TranscriptEntry(kind: .error, text: text))
            return
        }
        Diagnostics.log("turn mode=research")
        // Research runs for minutes. If the screen locks, iOS takes the GPU
        // away and the run is lost, so the screen stays on until it ends.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let entry = TranscriptEntry(
            kind: .activity, text: "",
            activity: ActivityLog(title: "Research: " + ResearchEngine.searchQuery(from: request))
        )
        transcript.append(entry)
        let entryID = entry.id
        // Found by id, not position: a late update must not land on another
        // entry after the conversation is cleared.
        let reporter = ActivityReporter { [weak self] change in
            guard let self,
                  let index = self.transcript.lastIndex(where: { $0.id == entryID }),
                  var log = self.transcript[index].activity
            else { return }
            change(&log)
            self.transcript[index].activity = log
        }
        activeReporter = (entryID, reporter)
        defer { activeReporter = nil }

        let store: ResearchStore
        do { store = try ResearchStore.open() }
        catch {
            transcript.append(TranscriptEntry(kind: .error, text: error.localizedDescription))
            return
        }
        researchOriginalModel = await runner.configuration()
        unavailableResearchModels = []

        let engine = ResearchEngine(
            request: request,
            budget: .hard,
            ask: { [weak self] system, user in
                guard let self else { throw CancellationError() }
                return try await self.ask(system: system, user: user)
            },
            activity: reporter,
            selection: selection?.candidate,
            extract: { try await WebSearch.extract($0) },
            store: store,
            resume: resume
        )

        let findings: ResearchEngine.Findings
        do {
            findings = try await engine.run()
        } catch {
            await restoreResearchModel()
            if Task.isCancelled || error is CancellationError {
                reporter.finish(reporter.begin("Research stopped"), .stopped)
                return
            }
            reporter.finish(reporter.begin("Research failed", detail: error.localizedDescription), .failed)
            transcript.append(TranscriptEntry(kind: .error, text: error.localizedDescription))
            return
        }
        await restoreResearchModel()
        readWebContent = true
        Diagnostics.log("research searches=\(findings.searches) pages=\(findings.pagesChecked) "
            + "matched=\(findings.pagesMatched) facts=\(findings.facts.count)")
        if !findings.candidates.isEmpty {
            var choices = TranscriptEntry(kind: .assistant, text: "Sources to inspect")
            choices.researchCandidates = findings.candidates
            choices.researchRequest = request
            transcript.append(choices)
        }

        guard !findings.facts.isEmpty else {
            let reply = findings.limitations.isEmpty
                ? (selection != nil
                    ? "No reliable extract was available from the selected profile. Its source link is above so you can inspect the page. "
                    : findings.candidates.isEmpty
                    ? "The searches returned no readable, relevant profiles. "
                    : "I found potential sources above. Choose ‘Research this profile’ to narrow the search. ")
                    + findings.identitySummary
                : "Research was incomplete: " + findings.limitations.joined(separator: " ")
            transcript.append(TranscriptEntry(kind: .assistant, text: reply))
            history.append(.assistant(reply))
            return
        }

        let writing = reporter.begin("Writing evidence report", detail: "Keeping each source profile and its quotations separate")
        var replyText = findings.run?.graph.report() ?? findings.facts.map { "- \($0.text) [\($0.site)](\($0.url.absoluteString))" }.joined(separator: "\n")
        replyText += "\n\n" + findings.identitySummary + "\n" + findings.stopReason
        if findings.combinationsSkipped > 0 || findings.pagesSkipped > 0 {
            replyText += "\nBudget omitted \(findings.combinationsSkipped) queries and \(findings.pagesSkipped) discovered pages."
        }
        if !findings.limitations.isEmpty { replyText += "\nSearch limitations: " + findings.limitations.joined(separator: " ") }
        replyText += "\n\nSources, dates, relationships and search history are saved in Sidebar → Research."
        reporter.finish(writing)
        transcript.append(TranscriptEntry(kind: .assistant, text: replyText))
        history.append(.assistant(replyText))
    }

    private func restoreResearchModel() async {
        guard let original = researchOriginalModel else { return }
        researchOriginalModel = nil
        // Finish restoring even if the research task was cancelled. Never leave
        // catalog selection pointing at a different resident model silently.
        let restore = Task { @MainActor in
            do { try await self.runner.load(directory: original.directory, displayName: original.name, adapterDirectory: original.adapter) }
            catch { self.transcript.append(TranscriptEntry(kind: .error, text: "The chat model could not be restored. Select it in Models. " + error.localizedDescription)) }
        }
        await restore.value
    }

    // MARK: - Pictures

    /// An activity entry and the reporter that updates it.
    private func startActivity(_ title: String) -> (entryID: UUID, reporter: ActivityReporter) {
        let entry = TranscriptEntry(kind: .activity, text: "", activity: ActivityLog(title: title))
        transcript.append(entry)
        let entryID = entry.id
        let reporter = ActivityReporter { [weak self] change in
            guard let self,
                  let index = self.transcript.lastIndex(where: { $0.id == entryID }),
                  var log = self.transcript[index].activity
            else { return }
            change(&log)
            self.transcript[index].activity = log
        }
        return (entryID, reporter)
    }

    /// Describes each picture with the image model (or Apple's Vision when
    /// there is none) and returns the descriptions for the chat model. Nil
    /// when the turn was stopped.
    private func readImages(_ ids: [UUID]) async -> String? {
        let activity = startActivity(ids.count == 1 ? "Reading your picture" : "Reading \(ids.count) pictures")
        let reporter = activity.reporter
        activeReporter = activity
        defer { activeReporter = nil }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var notes: [String] = []
        var useModel = visionModelDirectory != nil
        if let directory = visionModelDirectory {
            let loading = reporter.begin("Loading the image model", detail: directory.lastPathComponent)
            await waitUntilForeground()
            await runner.suspend()
            do {
                try await VisionRunner.shared.load(directory: directory)
                reporter.finish(loading)
            } catch {
                reporter.finish(loading, .failed, detail: error.localizedDescription)
                useModel = false
            }
        }

        for (number, id) in ids.enumerated() {
            if Task.isCancelled { break }
            let step = reporter.begin(ids.count == 1 ? "Reading the picture" : "Reading picture \(number + 1)",
                                      detail: useModel ? "Image model" : "Apple Vision (no image model on the phone)")
            guard let data = ImageStore.shared.modelData(id) else {
                reporter.finish(step, .failed, detail: "The picture could not be opened")
                continue
            }
            do {
                let text: String
                if useModel {
                    await waitUntilForeground()
                    isGenerating = true
                    defer { isGenerating = false }
                    text = try await VisionRunner.shared.describe(data, question: currentRequest)
                } else {
                    text = try await QuickVision.describe(data)
                }
                guard !text.isEmpty else {
                    reporter.finish(step, .failed, detail: "Nothing came back")
                    continue
                }
                notes.append(text)
                ImageStore.shared.setDescription(id, text)
                reporter.addItem(step, "What it sees", subtitle: String(text.prefix(160)), status: .done)
                reporter.finish(step)
            } catch {
                reporter.finish(step, Task.isCancelled ? .stopped : .failed, detail: error.localizedDescription)
            }
        }

        if visionModelDirectory != nil {
            await VisionRunner.shared.unload()
            let reload = reporter.begin("Bringing back the chat model")
            await waitUntilForeground()
            do {
                try await runner.resume()
                reporter.finish(reload)
            } catch {
                // It is loaded again on the next generation anyway.
                reporter.finish(reload, .failed, detail: error.localizedDescription)
            }
        }
        if Task.isCancelled { return nil }
        guard !notes.isEmpty else {
            transcript.append(TranscriptEntry(kind: .error, text: "The picture could not be read."))
            return nil
        }
        let listed = notes.enumerated().map { index, note -> String in
            "[Picture \(index + 1) that the user attached, as described by the image model]\n\(note)"
        }
        return listed.joined(separator: "\n\n")
            + "\n\nYou cannot see the pictures yourself; answer from these descriptions."
    }

    /// Makes a picture with the image model and shows it.
    private func createImage(_ prompt: String) async {
        let style = ImageGenerator.style(for: currentRequest)
        let activity = startActivity("Creating an image")
        let reporter = activity.reporter
        let step = reporter.begin("Drawing in the \(style.title.lowercased()) style", detail: prompt)
        await waitUntilForeground()
        do {
            let image = try await ImageGenerator.create(prompt, style: style)
            guard let stored = ImageStore.shared.addCreated(image, prompt: prompt, style: style.rawValue) else {
                throw ImageGenerator.GenerationError.noImage
            }
            reporter.finish(step)
            let lower = currentRequest.lowercased()
            var text = "Here\u{2019}s \(prompt)."
            if ["photo", "realistic", "real life", "photograph"].contains(where: { lower.contains($0) }) {
                text += " The image model on your phone draws in animation, illustration and sketch "
                    + "styles, so this is a drawing rather than a photo."
            }
            var reply = TranscriptEntry(kind: .assistant, text: text)
            reply.imageIDs = [stored.id]
            transcript.append(reply)
            history.append(.assistant("I made a \(style.title.lowercased()) image of \(prompt) and "
                + "showed it to the user."))
        } catch {
            reporter.finish(step, .failed, detail: error.localizedDescription)
            transcript.append(TranscriptEntry(kind: .error, text: error.localizedDescription))
        }
    }

    /// One short generation with no tools and no thinking, for the research
    /// checks. Waits for the foreground, as every generation must.
    /// The research check in progress. A skipped check can still be winding
    /// down when the next one starts, and two generations must never overlap.
    @ObservationIgnored private var checkInFlight: Task<String, Error>?

    private func ask(system: String, user: String) async throws -> String {
        while let previous = checkInFlight {
            _ = try? await previous.value
            if checkInFlight == previous { checkInFlight = nil }
        }
        await waitUntilForeground()
        try Task.checkCancellation()
        let runner = self.runner
        if let original = researchOriginalModel {
            let role = system == ResearchCoordinator.extractionPrompt ? "extractorModel" : "plannerModel"
            let path = UserDefaults.standard.string(forKey: "conduit.research." + role) ?? ""
            let target = path.isEmpty || unavailableResearchModels.contains(path) ? original.directory : URL(fileURLWithPath: path)
            do {
                try await runner.load(directory: target, displayName: target == original.directory ? original.name : target.lastPathComponent,
                                      adapterDirectory: target == original.directory ? original.adapter : nil)
            } catch {
                try Task.checkCancellation()
                unavailableResearchModels.insert(path)
                transcript.append(TranscriptEntry(kind: .assistant, text: "The optional research model could not be loaded; using the chat model. " + error.localizedDescription))
                try await runner.load(directory: original.directory, displayName: original.name, adapterDirectory: original.adapter)
            }
        }
        let task = Task { @MainActor () throws -> String in
            self.isGenerating = true
            defer { self.isGenerating = false }
            var text = ""
            var reasoningCharacters = 0
            for try await event in runner.stream(
                messages: [.system(system), .user(user)],
                tools: [],
                thinking: false,
                sampling: .extraction(maxTokens: system == ResearchCoordinator.extractionPrompt ? 640 : 320)
            ) {
                if case .text(let chunk) = event { text += chunk }
                if case .reasoning(let chunk) = event { reasoningCharacters += chunk.count }
            }
            Diagnostics.log("research.check textChars=\(text.count) reasoningChars=\(reasoningCharacters)")
            try Task.checkCancellation()
            return text
        }
        checkInFlight = task
        defer { if checkInFlight == task { checkInFlight = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func execute(_ call: ModelRunner.Message.Call) async {
        let name = call.name

        // Refused calls go back to the model only. The user asked a question,
        // not for a failed tool chip.
        let mcpServer = MCPStore.shared.server(forTool: name)
        let refusal: ToolOutcome?
        if !offeredTools.contains(name) {
            refusal = .failure(name, "Not run: \(name) is not available for this request. "
                + "Use only the tools you were given.")
        } else {
            refusal = ToolPolicy.refusal(
                for: name, request: currentRequest, previousReply: previousReply,
                afterWebContent: readWebContent,
                mcpServerName: mcpServer?.name
            )
        }
        if let refusal {
            Diagnostics.log("tool.blocked \(name)")
            history.append(.tool(refusal.modelResponseJSON, callID: call.id))
            return
        }
        Diagnostics.log("tool.run \(name)")
        // Web pages and outside servers both return text Conduit cannot trust.
        if TaskRouter.webToolNames.contains(name) || mcpServer != nil || name.hasPrefix(GoogleTools.prefix) {
            readWebContent = true
        } else if !TaskRouter.answerToolNames.contains(name) {
            usedPhoneTools = true
        }
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
