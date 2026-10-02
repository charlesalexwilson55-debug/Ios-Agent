import Foundation

enum ConduitMotion {
    static func position(at time: TimeInterval) -> Double {
        let rest = 0.24, travel = 0.14
        let cycle = 2 * (rest + travel)
        let phase = max(0, time).truncatingRemainder(dividingBy: cycle)
        func ease(_ fraction: Double) -> Double {
            let t = min(max(fraction, 0), 1)
            return t * t * (3 - 2 * t)
        }
        if phase < rest { return 0 }
        if phase < rest + travel { return ease((phase - rest) / travel) }
        if phase < 2 * rest + travel { return 1 }
        return 1 - ease((phase - 2 * rest - travel) / travel)
    }
}
