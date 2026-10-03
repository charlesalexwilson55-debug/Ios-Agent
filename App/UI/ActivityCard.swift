import SwiftUI

/// A long task shown as steps: what it is doing, what each action found,
/// and buttons to stop a step or skip one item while the rest carries on.
struct ActivityCard: View {
    let log: ActivityLog
    let accent: Color
    /// Stops a step or skips an item, by id.
    let onCancel: (UUID) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var showingDetails = false
    @AppStorage(Appearance.showActivityLabelKey) private var showActivityLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .overlay(alignment: .trailing) {
                    Button { withAnimation(.snappy(duration: 0.2)) { showingDetails.toggle() } } label: {
                        Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showingDetails ? "Hide research sources and activity" : "Show research sources and activity")
                }
            if showingDetails {
                ForEach(log.steps) { step in
                    stepRow(step)
                    if expanded.contains(step.id) || step.status == .running {
                        itemList(step)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var header: some View {
        if let running = log.steps.last(where: { $0.status == .running }) {
            ConduitLoader(color: accent, status: running.title)
        } else {
            VStack(spacing: 6) {
                Capsule().strokeBorder(.primary.opacity(0.65), lineWidth: 1.2)
                    .frame(width: 38, height: 13)
                    .overlay { Circle().fill(accent).frame(width: 7, height: 7) }
                if showActivityLabel {
                    Text(log.steps.last?.title ?? "Preparing research")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private var progressText: String {
        let done = log.steps.filter { $0.status != .running && $0.status != .waiting }.count
        return "\(done)/\(log.steps.count)"
    }

    private func stepRow(_ step: ActivityStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusIcon(status: step.status, accent: accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 14, weight: step.status == .running ? .semibold : .regular))
                if let detail = step.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            if step.cancellable, step.status == .running {
                Button("Stop") { onCancel(step.id) }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
            if !step.items.isEmpty, step.status != .running {
                Image(systemName: expanded.contains(step.id) ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture {
            guard !step.items.isEmpty, step.status != .running else { return }
            if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
        }
        .accessibilityElement(children: .combine)
    }

    private func itemList(_ step: ActivityStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(step.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    StatusIcon(status: item.status, accent: accent)
                        .scaleEffect(0.8)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        if let url = item.url {
                            Link(item.title, destination: url)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        } else {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                        }
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    if item.cancellable, item.status == .running {
                        Button("Skip") { onCancel(item.id) }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.leading, 26)
        .padding(.bottom, 6)
    }
}

private struct StatusIcon: View {
    let status: ActivityStep.Status
    let accent: Color

    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).tint(accent)
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.red)
        }
    }
}
