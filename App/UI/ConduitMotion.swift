import Foundation

enum NavigationLight {
    static func width(in track: Double) -> Double { min(24, max(0, track)) }

    static func offset(in track: Double, index: Int, count: Int, drag: Double? = nil) -> Double {
        let travel = max(0, track - width(in: track))
        let page = min(max(index, 0), max(0, count - 1))
        let position = drag ?? travel * Double(page) / Double(max(count - 1, 1))
        return min(max(position, 0), travel)
    }

    static func index(at x: Double, width: Double, count: Int) -> Int {
        guard width > 0, count > 1 else { return 0 }
        let fraction = min(max(x / width, 0), 1)
        return Int((fraction * Double(count - 1)).rounded())
    }
}

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
