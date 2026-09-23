import Foundation

/// A source to inspect, never an automatic assertion about a person's identity.
struct ResearchCandidate: Identifiable, Codable, Sendable {
    enum Status: String, Codable, Sendable { case possible, supported, conflicting, unreadable }
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    let snippet: String
    let status: Status
    let reason: String
    let matchedClues: [String]
    /// Bounded readable text retained in this live conversation. A provider may
    /// have read a site that a direct page load cannot access later.
    var sourceText: String? = nil
    var displayGroupID: String? = nil
    var sharedAttributes: [String]? = nil
}

struct ResearchSelection: Sendable {
    let request: String
    let candidate: ResearchCandidate
}
