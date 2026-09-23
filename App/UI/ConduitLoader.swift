import SwiftUI

/// Shown while the model is working: a ball rolls from one end of the
/// hollow conduit to the other, resting at each end for longer than it takes
/// to cross.
struct ConduitLoader: View {
    var color: Color
    var status: String?

    private static let length: CGFloat = 46
    private static let thickness: CGFloat = 16
    private static let ball: CGFloat = 9
    private static let stroke: CGFloat = 1.5
    /// Seconds resting at each end, and seconds crossing.
    private static let rest = 0.6
    private static let travel = 0.34

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let position = reduceMotion ? 0.5 : Self.position(at: context.date.timeIntervalSinceReferenceDate)
                let inset = Self.thickness * 0.5
                let span = Self.length - inset * 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: Self.stroke)
                        .shadow(color: .black.opacity(0.2), radius: 1)
                        .frame(width: Self.length, height: Self.thickness)
                    Circle()
                        .fill(color)
                        .frame(width: Self.ball, height: Self.ball)
                        .offset(x: inset - Self.ball / 2 + span * position)
                }
                .frame(width: Self.length, height: Self.thickness, alignment: .leading)
            }
            if let status {
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "Working")
    }

    /// 0 at the left end, 1 at the right: rest, cross, rest, cross back.
    static func position(at time: TimeInterval) -> Double {
        let cycle = 2 * (rest + travel)
        let phase = time.truncatingRemainder(dividingBy: cycle)
        func eased(_ fraction: Double) -> Double {
            let t = min(max(fraction, 0), 1)
            return t * t * (3 - 2 * t)
        }
        switch phase {
        case ..<rest:
            return 0
        case ..<(rest + travel):
            return eased((phase - rest) / travel)
        case ..<(2 * rest + travel):
            return 1
        default:
            return 1 - eased((phase - 2 * rest - travel) / travel)
        }
    }
}
