import SwiftUI

/// Search results that may describe the requested person. The user can inspect
/// the evidence and choose which profile deserves deeper research; a candidate
/// is never treated as an identity confirmation.
struct ResearchCandidatesView: View {
    let candidates: [ResearchCandidate]
    let isWorking: Bool
    let onSelect: (ResearchCandidate) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(groupIDs, id: \.self) { groupID in
                let members = candidates.filter { ($0.displayGroupID ?? $0.id) == groupID }
                VStack(alignment: .leading, spacing: 10) {
                    if members.count > 1, let shared = members.first?.sharedAttributes, !shared.isEmpty {
                        Text("\(members.count) sources with shared details").font(.headline)
                        Text(shared.joined(separator: " · ")).font(.subheadline)
                        Text("Shared attributes are not proof of the same identity.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(members) { candidate in candidateCard(candidate) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupIDs: [String] {
        var seen = Set<String>()
        return candidates.map { $0.displayGroupID ?? $0.id }.filter { seen.insert($0).inserted }
    }

    private func candidateCard(_ candidate: ResearchCandidate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(domain(for: candidate.url))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusLabel(candidate.status)
            }

            Text(candidate.reason)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)

            if !candidate.snippet.isEmpty {
                Text(candidate.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !candidate.matchedClues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supplied clues mentioned on the page")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.matchedClues.joined(separator: "  •  "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.conduitAccent)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Link(destination: candidate.url) {
                    Label("Open source", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button("Research this profile") {
                    onSelect(candidate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.conduitAccent)
                .disabled(isWorking)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func statusLabel(_ status: ResearchCandidate.Status) -> some View {
        let presentation: (title: String, symbol: String, color: Color) = switch status {
        case .possible:
            ("Possible", "questionmark.circle.fill", .blue)
        case .supported:
            ("Supported", "checkmark.circle.fill", .green)
        case .conflicting:
            ("Conflicting", "exclamationmark.triangle.fill", .orange)
        case .unreadable:
            ("Unreadable", "eye.slash.fill", Color.secondary)
        }

        return Label(presentation.title, systemImage: presentation.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(presentation.color.opacity(0.11), in: .capsule)
            .fixedSize()
    }

    private func domain(for url: URL) -> String {
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
