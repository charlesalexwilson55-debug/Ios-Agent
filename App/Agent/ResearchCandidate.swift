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
    var profileFields: [String]? = nil
    /// A user decision, never a claim of verified identity.
    var decision: String? = nil

    var profileLabel: String { profileFields?.joined(separator: ", ") ?? title }
    var identityKey: String { displayGroupID ?? id }

    static func visible(_ candidates: [Self], earlier: [Self], selectedID: String? = nil) -> [Self] {
        var result = candidates.map { candidate in
            var result = candidate
            result.decision = earlier.last(where: { $0.decision != nil && ($0.id == candidate.id || $0.identityKey == candidate.identityKey) })?.decision
            if selectedID == candidate.id { result.decision = "selected" }
            return result
        }
        for index in result.indices where result[index].decision == nil {
            let key = result[index].identityKey
            let decision = result.first(where: { $0.identityKey == key && $0.decision != nil })?.decision
            result[index].decision = decision
        }
        return result.filter { $0.decision != "rejected" }
    }
}

struct ResearchSelection: Sendable {
    let request: String
    let candidate: ResearchCandidate
}
