import Foundation

/// Cancellation-aware FIFO admission. Actor isolation alone does not prevent
/// overlapping generations while a previous generation awaits GPU output.
actor InferenceGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if !held { held = true; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
