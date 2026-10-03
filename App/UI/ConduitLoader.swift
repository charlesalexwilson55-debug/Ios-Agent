import SwiftUI

/// A bounded, centered indicator; no decorative delay before showing an answer.
struct ConduitLoader: View {
    var color: Color
    var status: String?
    var finishingSince: Date? = nil
    @AppStorage(Appearance.showActivityLabelKey) private var showActivityLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let position = reduceMotion ? 0.5 : ConduitMotion.position(at: context.date.timeIntervalSince(started))
                ZStack {
                    Capsule().strokeBorder(.primary.opacity(0.65), lineWidth: 1.2)
                    Circle().fill(color.gradient)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(0.45), radius: 3)
                        .offset(x: CGFloat(position - 0.5) * 24)
                }
                .frame(width: 38, height: 13)
            }
            if showActivityLabel, let status {
                Text(status).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "Working")
        .allowsHitTesting(false)
    }

    static func position(at time: TimeInterval) -> Double { ConduitMotion.position(at: time) }
}
