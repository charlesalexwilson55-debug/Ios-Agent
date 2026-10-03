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
        // Layout changes and off-screen drags must never push the light outside its track.
        for width in [0.0, 8, 24, 120, 390] {
            for count in [1, 4] {
                for index in -1...count {
                    for drag in [nil, -100.0, 0, 100, 1000] as [Double?] {
                        let offset = NavigationLight.offset(in: width, index: index, count: count, drag: drag)
                        precondition(offset >= 0 && offset + NavigationLight.width(in: width) <= width)
                    }
                }
            }
        }
        precondition(NavigationLight.index(at: -20, width: 300, count: 4) == 0)
        precondition(NavigationLight.index(at: 320, width: 300, count: 4) == 3)
        precondition(NavigationLight.index(at: 200, width: 300, count: 4) == 2)
        precondition(NavigationLight.offset(in: 300, index: 2, count: 4) == 184)
        print("Usage ranks, bounded loading motion and navigation light passed")
    }
}
