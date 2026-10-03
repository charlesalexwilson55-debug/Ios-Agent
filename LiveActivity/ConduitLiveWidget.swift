import ActivityKit
import SwiftUI
import WidgetKit

@main struct ConduitLiveWidgets: WidgetBundle {
    var body: some Widget { ConduitLiveWidget() }
}

struct ConduitLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConduitActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ConduitActivityMark(paused: context.state.paused)
                Text(context.state.status).font(.callout.weight(.medium))
                Spacer()
            }
            .padding(18)
            .foregroundStyle(.white)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ConduitActivityMark(paused: context.state.paused) }
                DynamicIslandExpandedRegion(.trailing) { orb(paused: context.state.paused) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.caption).foregroundStyle(.white)
                }
            } compactLeading: {
                Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                    .frame(width: 19, height: 9)
            } compactTrailing: {
                orb(paused: context.state.paused)
            } minimal: {
                orb(paused: context.state.paused)
            }
            .keylineTint(.white.opacity(0.8))
        }
    }

    private func orb(paused: Bool) -> some View {
        Circle().fill(Color.blue.gradient).frame(width: 8, height: 8)
            .opacity(paused ? 0.55 : 1)
            .shadow(color: .blue.opacity(0.65), radius: 3)
            .accessibilityLabel(paused ? "Paused" : "Working")
    }
}

private struct ConduitActivityMark: View {
    var paused: Bool
    var body: some View {
        Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
            .frame(width: 38, height: 13)
            .overlay(alignment: .trailing) {
                Circle().fill(Color.blue.gradient).frame(width: 7, height: 7)
                    .opacity(paused ? 0.55 : 1).padding(.trailing, 3)
            }
    }
}
