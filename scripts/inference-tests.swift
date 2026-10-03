import Foundation

private actor Probe {
    var active = 0
    var peak = 0
    var completed = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1; completed += 1 }
    func check() { precondition(peak == 1 && active == 0 && completed == 24, "GPU jobs must never overlap or disappear") }
}

@main struct InferenceTests {
    static func main() async throws {
        let gate = InferenceGate()
        let probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await gate.acquire()
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(2))
                    await probe.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
        await probe.check()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire(); await gate.release() }
        await Task.yield()
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancelled queued job was admitted") }
        catch is CancellationError {}
        await gate.release()
        try await gate.acquire()
        await gate.release()

        let prior = "Research Payton Example, Harbour NSW, soccer"
        let cases: [(String, ResearchTurnRouter.Route)] = [
            ("Payton is a boy", .correction), ("he is not a girl", .correction),
            ("he's a boy", .correction), ("Payton’s a boy", .correction), ("he/him", .correction),
            ("Actually, Payton lives in Sydney", .correction), ("Payton is a teacher", .correction),
            ("thanks", .conversation), ("why did you search that?", .conversation),
            ("what did you find?", .conversation), ("write some code", .conversation),
            ("open calendar", .conversation),
            ("research Taylor Example", .research("research Taylor Example")),
            ("can you research quantum computing", .research("can you research quantum computing")),
            ("Taylor Example, Sydney, teacher", .research("Taylor Example, Sydney, teacher"))
        ]
        for (message, expected) in cases {
            precondition(ResearchTurnRouter.route(message, enabled: true, previousRequest: prior) == expected, "Wrong routing: \(message)")
        }
        if case .research(let continued) = ResearchTurnRouter.route("find more", enabled: true, previousRequest: prior) {
            precondition(continued.hasPrefix(prior) && continued.contains("additional public information"))
        } else { preconditionFailure("Follow-up lost its research subject") }
        precondition(ResearchTurnRouter.route("Payton is a boy", enabled: false, previousRequest: nil) == .correction)
        print("Inference queue isolation, queued cancellation, permit recovery and research conversation routing passed")
    }
}
