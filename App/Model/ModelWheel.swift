import Foundation

enum ModelWheel {
    static func index(rotation: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let step = 360.0 / Double(count)
        let value = Int((-rotation / step).rounded())
        return ((value % count) + count) % count
    }
}
