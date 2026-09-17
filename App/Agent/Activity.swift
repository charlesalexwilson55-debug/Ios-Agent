import Foundation

/// What a long piece of work is doing, step by step, for the chat to show.
///
/// It records actions and results (searches run, pages read, what each one
/// gave), not the model's hidden reasoning.
struct ActivityLog: Equatable {
    var title: String
    var steps: [ActivityStep] = []
}

struct ActivityStep: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting, running, done, failed, skipped, stopped
    }

    let id = UUID()
    var title: String
    var detail: String?
    var status: Status = .running
    var items: [ActivityItem] = []
    /// Whether the user can stop this step on its own.
    var cancellable = false
}

struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var url: URL?
    var status: ActivityStep.Status = .running
    /// Whether the user can skip this one operation.
    var cancellable = false
}

/// Updates one activity entry in the chat, and lets the user stop a step or
/// skip an item while the rest of the work carries on.
@MainActor
final class ActivityReporter {
    typealias Apply = @MainActor ((inout ActivityLog) -> Void) -> Void

    private let apply: Apply
    private var stopped: Set<UUID> = []
    /// Cancels the operation running for an item, keyed by item id.
    private var running: [UUID: () -> Void] = [:]
    private var stepOfItem: [UUID: UUID] = [:]

    init(apply: @escaping Apply) {
        self.apply = apply
    }

    // MARK: - Steps

    @discardableResult
    func begin(_ title: String, detail: String? = nil, cancellable: Bool = false) -> UUID {
        let step = ActivityStep(title: title, detail: detail, cancellable: cancellable)
        apply { $0.steps.append(step) }
        return step.id
    }

    func setTitle(_ step: UUID, _ title: String) {
        change(step) { $0.title = title }
    }

    func setDetail(_ step: UUID, _ detail: String?) {
        change(step) { $0.detail = detail }
    }

    func finish(_ step: UUID, _ status: ActivityStep.Status = .done, detail: String? = nil) {
        let final: ActivityStep.Status = stopped.contains(step) ? .stopped : status
        change(step) {
            $0.status = final
            $0.cancellable = false
            if let detail { $0.detail = detail }
            for index in $0.items.indices where $0.items[index].status == .running {
                $0.items[index].status = final == .done ? .skipped : final
                $0.items[index].cancellable = false
            }
        }
    }

    func isStopped(_ step: UUID) -> Bool {
        stopped.contains(step)
    }

    // MARK: - Items

    @discardableResult
    func addItem(_ step: UUID, _ title: String, subtitle: String? = nil, url: URL? = nil,
                 status: ActivityStep.Status = .running, cancellable: Bool = false) -> UUID {
        let item = ActivityItem(title: title, subtitle: subtitle, url: url, status: status, cancellable: cancellable)
        stepOfItem[item.id] = step
        change(step) { $0.items.append(item) }
        return item.id
    }

    func updateItem(_ item: UUID, subtitle: String? = nil, status: ActivityStep.Status? = nil) {
        guard let step = stepOfItem[item] else { return }
        change(step) { value in
            guard let index = value.items.firstIndex(where: { $0.id == item }) else { return }
            if let subtitle { value.items[index].subtitle = subtitle }
            if let status {
                value.items[index].status = status
                if status != .running { value.items[index].cancellable = false }
            }
        }
    }

    // MARK: - Stopping

    /// Stops a step (and whatever it is running), or skips one item.
    func cancel(_ id: UUID) {
        stopped.insert(id)
        if let cancelItem = running[id] {
            cancelItem()
            return
        }
        for (item, step) in stepOfItem where step == id {
            running[item]?()
        }
        change(id) { $0.cancellable = false; $0.detail = "Stopping\u{2026}" }
    }

    /// Runs one operation that the user can skip. Returns nil when it was
    /// skipped or its step was stopped; throws when the whole run was
    /// cancelled.
    func run<T: Sendable>(_ item: UUID, _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        if let step = stepOfItem[item], stopped.contains(step) { return nil }
        let task = Task { @MainActor in try await operation() }
        running[item] = { task.cancel() }
        defer { running[item] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled { throw error }
            if error is CancellationError || stopped.contains(item) { return nil }
            if let step = stepOfItem[item], stopped.contains(step) { return nil }
            throw error
        }
    }

    private func change(_ step: UUID, _ edit: @escaping (inout ActivityStep) -> Void) {
        apply { log in
            guard let index = log.steps.firstIndex(where: { $0.id == step }) else { return }
            edit(&log.steps[index])
        }
    }
}
