import Foundation

struct ResearchQuery: Codable, Sendable {
    let text: String
    let purpose: String
    var evidenceIDs: [String] = []
}

struct ResearchRun: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case planning, searching, extracting, resolving, verifying, gapAnalysis, report
    }
    struct Search: Codable, Identifiable, Sendable {
        let id: String
        let query: ResearchQuery
        let date: Date
        var provider: String = ""
        var status: String = "started"
        var urls: [URL] = []
        var error: String?
    }
    struct PendingSource: Codable, Sendable {
        let title: String
        let url: URL
        let summary: String
        let published: String?
        var text: String?
        let provider: String
    }
    let id: UUID
    let request: String
    let created: Date
    var updated: Date
    var stage: Stage = .planning
    var completed = false
    var paused = false
    var plan: ResearchPlan?
    var selection: ResearchCandidate?
    var budget: ResearchEngine.Budget
    var graph = ResearchGraph()
    var pendingQueries: [ResearchQuery] = []
    var pendingSources: [PendingSource] = []
    var searchesLog: [Search] = []
    var usedQueries: [String] = []
    var visitedURLs: [String] = []
    var searches = 0
    var pages = 0
    var skippedPages = 0
    var skippedQueries = 0
    var round = 0
    var modelCalls = 0
    /// Conservative byte accounting bounds model input/output, including retries.
    var modelBytes = 0
    var activeSeconds: Double = 0
    var previousClaims = 0
    var previousEntities = 0
    var previousCorroborated = 0
    var previousUnresolved = 0
    var stagnantRounds = 0
    var limitations: [String] = []
    var stopReason = ""

    init(request: String, budget: ResearchEngine.Budget, selection: ResearchCandidate? = nil) {
        id = UUID(); created = Date(); updated = created
        self.request = request; self.budget = budget; self.selection = selection
    }

    var canResume: Bool { !completed }
}
