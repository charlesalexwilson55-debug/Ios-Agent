import Foundation

/// Engagement ranks measure recorded generations, never model intelligence.
enum UsageRank {
    static let thresholds = [0, 5, 15, 30, 60, 100, 175, 300, 500, 800, 1200, 1800, 2600, 4000, 6000]
    static let names = ["Newcomer", "Explorer", "Regular", "Collaborator", "Problem Solver",
        "Builder", "Researcher", "Specialist", "Creator", "Trailblazer", "Strategist",
        "Innovator", "Expert", "Master", "Pioneer"]
    static func level(replies: Int) -> Int {
        thresholds.lastIndex(where: { max(0, replies) >= $0 }) ?? 0
    }
}
