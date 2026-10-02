import Foundation

@main struct ExperienceTests {
    static func main() {
        precondition(UsageRank.level(replies: 0) == 0)
        precondition(UsageRank.level(replies: 5) == 1)
        precondition(UsageRank.level(replies: 100_000) == 14)
        precondition(UsageRank.names.count == 15)
        for index in 1..<UsageRank.thresholds.count {
            precondition(UsageRank.thresholds[index] > UsageRank.thresholds[index - 1])
        }
        for step in 0...1000 {
            let value = ConduitMotion.position(at: Double(step) / 100)
            precondition((0...1).contains(value), "Orb must remain inside its capsule")
        }
        precondition(ConduitMotion.position(at: 0) == 0)
        precondition(ConduitMotion.position(at: 0.4) == 1)
        print("Usage ranks and bounded loading motion passed")
    }
}
