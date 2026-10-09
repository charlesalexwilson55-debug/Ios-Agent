import Foundation
import MLX
import Observation
import SwiftUI
import UIKit

/// Explicit USB-imported QA. No personal recall, chat history, persistent model
/// selection, or real phone actions are involved in an evaluation.
@MainActor @Observable final class DeviceEvaluation {
    struct Case: Codable {
        let id: String
        let category: String
        let prompt: String
        let tools: [String]
        let fixtures: [String: String]
    }
    struct Request: Codable {
        let id: String
        let models: [String]
        let cases: [Case]
        let maxTokens: Int
    }
    struct Result: Codable {
        let model: String
        let caseID: String
        let category: String
        var answer = ""
        var rawAnswer = ""
        var calls: [ModelRunner.Message.Call] = []
        var error: String?
        var elapsedSeconds = 0.0
        var tokensPerSecond: Double?
        var peakActiveMB = 0
        var availableMB = 0
        var status = "completed"
    }
    struct Checkpoint: Codable { let model: String; let caseID: String; var phase = "case" }
    @MainActor private final class PartialResult {
        var value: Result
        init(_ value: Result) { self.value = value }
    }
    private(set) var isRunning = false
    private(set) var status = "Preparing device tests"
    private(set) var completed = 0
    private(set) var total = 0
    private var task: Task<Void, Never>?
    private var stopped = false
    private var paused = false
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evaluation", isDirectory: true)
    }
    static var requestURL: URL { root.appendingPathComponent("request.json") }
    static var hasRequest: Bool { FileManager.default.fileExists(atPath: requestURL.path) }
    func pause() { paused = true; task?.cancel() }
    func stop() { stopped = true; task?.cancel() }

    func run(catalog: ModelCatalog, runner: ModelRunner) async {
        // A foreground event can arrive while the paused worker still drains
        // GPU generation. Resume only after that worker releases its model.
        while isRunning && paused {
            guard UIApplication.shared.applicationState == .active else { return }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        guard !isRunning, UIApplication.shared.applicationState == .active, Self.hasRequest else { return }
        isRunning = true; stopped = false; paused = false
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let work = Task { await execute(catalog: catalog, runner: runner) }
        task = work
        await work.value
        task = nil; isRunning = false
    }

    private func execute(catalog: ModelCatalog, runner: ModelRunner) async {
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: Self.requestURL))
            guard request.id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  (1...100).contains(request.cases.count), (1...12).contains(request.models.count),
                  Set(request.cases.map(\.id)).count == request.cases.count,
                  Set(request.models).count == request.models.count,
                  (64...1024).contains(request.maxTokens) else { throw EvaluationError.invalidRequest }
            let folder = Self.root.appendingPathComponent(request.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let resultsURL = folder.appendingPathComponent("results.jsonl")
            let checkpointURL = folder.appendingPathComponent("checkpoint.json")
            let originalURL = folder.appendingPathComponent("request-snapshot.json")
            let requestData = try Data(contentsOf: Self.requestURL)
            if FileManager.default.fileExists(atPath: originalURL.path) {
                guard try Data(contentsOf: originalURL) == requestData else { throw EvaluationError.invalidRequest }
            } else { try requestData.write(to: originalURL, options: .atomic) }
            let oldData = (try? Data(contentsOf: resultsURL)) ?? Data()
            var results = oldData.split(separator: 10).compactMap { try? JSONDecoder().decode(Result.self, from: Data($0)) }
            if let data = try? Data(contentsOf: checkpointURL),
               let pending = try? JSONDecoder().decode(Checkpoint.self, from: data) {
                let interrupted = request.cases.filter { item in
                    (pending.phase == "load" || item.id == pending.caseID)
                        && !results.contains { $0.model == pending.model && $0.caseID == item.id }
                }
                for item in interrupted {
                    var result = Result(model: pending.model, caseID: item.id, category: item.category)
                    result.status = pending.phase == "load" ? "blocked_load" : "interrupted"
                    result.error = pending.phase == "load"
                        ? "The process ended while loading this model. Other cases are blocked until its load failure is diagnosed."
                        : "The process ended before this case produced a result. Check device diagnostics."
                    results.append(result)
                }
                try persist(results, to: resultsURL)
            }
            total = request.models.count * request.cases.count; completed = results.count
            let available = catalog.models + catalog.visionModels
            let specs = ToolRegistry.standard().specs
            for name in request.models {
                let pending = request.cases.filter { item in !results.contains { $0.model == name && $0.caseID == item.id } }
                if pending.isEmpty { continue }
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
                status = "Loading \(name)"
                try JSONEncoder().encode(Checkpoint(model: name, caseID: pending[0].id, phase: "load"))
                    .write(to: checkpointURL, options: .atomic)
                await VisionRunner.shared.unload()
                await runner.unload()
                var loadError: String?
                do {
                    guard let model = available.first(where: { $0.directory.lastPathComponent == name }) else {
                        throw EvaluationError.modelNotInstalled(name)
                    }
                    try await runner.load(directory: model.directory, displayName: name)
                } catch {
                    if Task.isCancelled { try? FileManager.default.removeItem(at: checkpointURL); throw CancellationError() }
                    loadError = error.localizedDescription
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: checkpointURL); throw CancellationError() }
                for item in pending {
                    try Task.checkCancellation()
                    guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
                    status = "\(name) · \(completed + 1)/\(total) · \(item.id)"
                    try JSONEncoder().encode(Checkpoint(model: name, caseID: item.id)).write(to: checkpointURL, options: .atomic)
                    var result: Result
                    if let loadError {
                        result = Result(model: name, caseID: item.id, category: item.category)
                        result.status = "blocked_load"; result.error = loadError
                    } else {
                        result = await answer(item, model: name, runner: runner, specs: specs, maxTokens: request.maxTokens)
                    }
                    if paused { try? FileManager.default.removeItem(at: checkpointURL); throw CancellationError() }
                    results.append(result)
                    try persist(results, to: resultsURL)
                    try? FileManager.default.removeItem(at: checkpointURL)
                    completed = results.count
                    Diagnostics.log("evaluation model=\(name) case=\(item.id) status=\(result.status) seconds=\(Int(result.elapsedSeconds))")
                }
                await runner.unload()
            }
            try FileManager.default.moveItem(at: Self.requestURL, to: folder.appendingPathComponent("completed-request.json"))
            status = "Device tests complete · \(completed) results saved"
        } catch is CancellationError {
            status = stopped ? "Tests stopped" : "Tests paused · reopen Conduit to resume"
            if stopped {
                try? FileManager.default.moveItem(at: Self.requestURL, to: Self.root.appendingPathComponent("stopped-\(UUID().uuidString).json"))
            }
        } catch {
            status = "Test request failed: \(error.localizedDescription)"
            try? FileManager.default.moveItem(at: Self.requestURL, to: Self.root.appendingPathComponent("invalid-\(UUID().uuidString).json"))
        }
        await runner.unload()
    }

    private func answer(_ item: Case, model: String, runner: ModelRunner,
                        specs: [ToolDescriptor], maxTokens: Int) async -> Result {
        let began = Date()
        MLX.Memory.peakMemory = 0
        let offered = specs.filter { item.tools.contains($0.name) }
        let mode: SystemPrompt.Mode = item.category == "tasks" ? .task : .answer
        let seed = Result(model: model, caseID: item.id, category: item.category)
        var result = seed
        let partial = PartialResult(seed)
        do {
            result = try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask { @MainActor in
                    var output = seed
                    var messages: [ModelRunner.Message] = [.system(SystemPrompt.build(tools: offered, mode: mode)), .user(item.prompt)]
                    for _ in 0..<4 {
                        try Task.checkCancellation()
                        var text = ""
                        var calls: [ModelRunner.Message.Call] = []
                        for try await event in runner.stream(messages: messages, tools: offered, thinking: false,
                                                              sampling: .extraction(maxTokens: maxTokens)) {
                            try Task.checkCancellation()
                            switch event {
                            case .text(let chunk): text += chunk
                            case .reasoning: break
                            case .toolCall(let id, let name, let arguments): calls.append(.init(id: id ?? UUID().uuidString, name: name, arguments: arguments))
                            case .finished(let rate): output.tokensPerSecond = rate
                            }
                            partial.value = output
                            partial.value.rawAnswer = text
                            partial.value.answer = ResponseTextCleaner.clean(text, streaming: true)
                            partial.value.calls = output.calls + calls
                        }
                        output.rawAnswer = text; output.answer = ResponseTextCleaner.clean(text); output.calls += calls
                        if calls.isEmpty { return output }
                        messages.append(.assistant(text, calls: calls))
                        for call in calls {
                            let response: String
                            if !offered.contains(where: { $0.name == call.name }) {
                                response = #"{"ok":false,"error":"This tool was not offered."}"#
                            } else if call.name == "run_javascript" {
                                response = await CodeTools().run(call.name, arguments: call.arguments).modelResponseJSON
                            } else {
                                response = item.fixtures[call.name] ?? #"{"ok":false,"error":"No fixture is available for this tool."}"#
                            }
                            messages.append(.tool(response, callID: call.id))
                        }
                    }
                    output.status = "tool_iteration_limit"; output.error = "The model exceeded four tool rounds."
                    return output
                }
                group.addTask { try await Task.sleep(for: .seconds(240)); throw EvaluationError.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            result = partial.value
            result.status = error is CancellationError ? "cancelled" : "error"
            result.error = error.localizedDescription
        }
        result.elapsedSeconds = Date().timeIntervalSince(began)
        result.peakActiveMB = MLX.Memory.peakMemory / 1_048_576
        result.availableMB = Diagnostics.availableMB
        return result
    }
    private func persist(_ results: [Result], to url: URL) throws {
        var data = Data()
        for result in results { data.append(try JSONEncoder().encode(result)); data.append(10) }
        try data.write(to: url, options: .atomic)
    }
    enum EvaluationError: LocalizedError {
        case invalidRequest, timeout, modelNotInstalled(String)
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "Invalid or oversized device evaluation request."
            case .timeout: "No completed answer within 240 seconds."
            case .modelNotInstalled(let name): "Model not installed: \(name)"
            }
        }
    }
}

struct DeviceEvaluationView: View {
    let evaluation: DeviceEvaluation
    var body: some View {
        VStack(spacing: 18) {
            ConduitLoader(color: .conduitAccent, status: "Testing models")
            Text(evaluation.status).multilineTextAlignment(.center)
            ProgressView(value: Double(evaluation.completed), total: Double(max(1, evaluation.total)))
            Text("Keep Conduit open. Phone actions are simulated. Results stay on this device.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Stop tests", role: .cancel) { evaluation.stop() }.buttonStyle(.bordered)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(BackdropView())
    }
}
