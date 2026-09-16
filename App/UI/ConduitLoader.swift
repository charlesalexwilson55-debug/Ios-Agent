import SwiftUI

/// A short white pipe with flanged ends: the app's namesake.
struct ConduitTube: View {
    var length: CGFloat = 44
    var thickness: CGFloat = 14
    var color: Color = .white

    var body: some View {
        ZStack {
            Capsule()
                .fill(color)
                .frame(width: length - thickness * 0.3, height: thickness)
            HStack {
                flange
                Spacer(minLength: 0)
                flange
            }
            .frame(width: length)
        }
        .frame(width: length, height: thickness * 1.35)
    }

    private var flange: some View {
        RoundedRectangle(cornerRadius: thickness * 0.18, style: .continuous)
            .fill(color)
            .frame(width: thickness * 0.34, height: thickness * 1.35)
    }
}

/// Shown while the model is working: a ball rolls from one end of the
/// conduit to the other, resting at each end for longer than it takes to
/// cross.
struct ConduitLoader: View {
    var color: Color
    var status: String?

    private static let length: CGFloat = 46
    private static let thickness: CGFloat = 16
    private static let ball: CGFloat = 9
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
                    ConduitTube(length: Self.length, thickness: Self.thickness)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    Circle()
                        .fill(color)
                        .frame(width: Self.ball, height: Self.ball)
                        .offset(x: inset - Self.ball / 2 + span * position)
                }
                .frame(width: Self.length, height: Self.thickness * 1.35, alignment: .leading)
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

/// The Settings icon: conduits crossed into a star, each with its ball at a
/// different point along it.
struct ConduitStarIcon: View {
    var size: CGFloat = 24
    var color: Color = .primary

    private static let arms: [(angle: Double, ball: CGFloat, tint: Color)] = [
        (0, 0.12, .orange),
        (45, 0.8, .pink),
        (90, 0.35, .green),
        (135, 0.6, .blue),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.arms.indices, id: \.self) { index in
                let arm = Self.arms[index]
                let length = size
                let thickness = size * 0.2
                let inset = thickness * 0.5
                ZStack(alignment: .leading) {
                    ConduitTube(length: length, thickness: thickness, color: color)
                    Circle()
                        .fill(arm.tint)
                        .frame(width: thickness * 0.62, height: thickness * 0.62)
                        .offset(x: inset - thickness * 0.31 + (length - inset * 2) * arm.ball)
                }
                .frame(width: length, height: thickness * 1.35, alignment: .leading)
                .rotationEffect(.degrees(arm.angle))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
