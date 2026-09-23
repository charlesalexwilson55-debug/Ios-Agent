import SwiftUI

/// Stored sources remain readable offline. Resuming is an explicit user action;
/// it continues the checkpoint's remaining budgets, not a new unlimited run.
struct ResearchArchiveView: View {
    let isWorking: Bool
    let canResume: Bool
    let onResume: (ResearchRun) -> Void
    @State private var runs: [ResearchRun] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Research archive") {
                    if runs.isEmpty { Text("Research runs and their evidence will appear here, including interrupted work.").foregroundStyle(.secondary) }
                    ForEach(runs) { run in
                        NavigationLink {
                            ResearchRunView(run: run, isWorking: isWorking, canResume: canResume, onResume: onResume)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.request).lineLimit(2)
                                Text("\(run.graph.sources.count) sources · \(run.graph.claims.count) claims · \(run.completed ? "Complete" : "Saved at " + run.stage.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(run.updated, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indices in
                        do {
                            let store = try ResearchStore.open()
                            for index in indices { try store.delete(runs[index].id) }
                            refresh()
                        } catch { self.error = error.localizedDescription }
                    }
                    .deleteDisabled(isWorking)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Research")
            .onAppear(perform: refresh)
            .refreshable { refresh() }
        }
    }
    private func refresh() {
        do { runs = try ResearchStore.open().list(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct ResearchRunView: View {
    let run: ResearchRun
    let isWorking: Bool
    let canResume: Bool
    let onResume: (ResearchRun) -> Void
    var body: some View {
        List {
            Section {
                Text(run.request)
                Text("\(run.searches) search queries · \(run.pages) pages · \(run.round) rounds").font(.caption)
                if !run.stopReason.isEmpty { Text(run.stopReason).font(.footnote) }
                if run.canResume {
                    Button("Resume saved research") { onResume(run) }.disabled(isWorking || !canResume)
                    Text("Requires a loaded model and an internet connection. Completed searches and evidence are retained.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Progress") }
            Section("Identities and evidence") {
                ForEach(run.graph.candidates) { candidate in
                    if let source = run.graph.sources.first(where: { $0.id == candidate.sourceID }) {
                        DisclosureGroup(source.title) {
                            Text(candidate.reason).font(.footnote)
                            Text("Evidence score \(candidate.score)/100 — an uncalibrated rule score, not identity certainty.").font(.caption)
                            Text("Identity group: \(candidate.groupID.prefix(8))").font(.caption2)
                            Link(source.url.host ?? "Open source", destination: source.url)
                            Text("Retrieved \(source.retrieved.formatted())").font(.caption2)
                            if let published = source.published { Text("Published: " + published).font(.caption2) }
                            if source.duplicateOf != nil { Label("Copied or substantially overlapping text; not independent evidence", systemImage: "doc.on.doc").font(.caption) }
                            ForEach(run.graph.claims.filter { $0.subjectID == candidate.entityID }) { claim in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(claim.predicate + " · " + claim.status.rawValue).font(.caption.bold())
                                    Text(claim.text).font(.footnote).textSelection(.enabled)
                                    if let period = claim.period { Text("Stated period: " + period).font(.caption2) }
                                }.padding(.vertical, 4)
                            }
                            DisclosureGroup("Saved source text") { Text(source.text).font(.footnote).textSelection(.enabled) }
                        }
                    }
                }
            }
            Section("Documented relationships") {
                ForEach(run.graph.relationships) { edge in
                    let subject = run.graph.entities.first { $0.id == edge.subjectID }?.label ?? "Subject"
                    let object = run.graph.entities.first { $0.id == edge.objectID }?.label ?? "Object"
                    Text(subject + " → " + edge.predicate + " → " + object).font(.footnote)
                }
                Text("Only directly quoted relationships are recorded. A connection through another person does not establish a new relationship.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Unresolved differences") {
                ForEach(run.graph.contradictions) { item in
                    DisclosureGroup(item.detail) {
                        ForEach(run.graph.claims.filter { item.claimIDs.contains($0.id) }) { claim in Text(claim.text).font(.footnote) }
                    }
                }
            }
            Section("Search history") {
                ForEach(run.searchesLog) { item in
                    DisclosureGroup(item.query.text) {
                        Text(item.query.purpose).font(.footnote)
                        Text(item.provider + " · " + item.status).font(.caption)
                        if let error = item.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                        ForEach(item.urls, id: \.self) { url in Link(url.host ?? url.absoluteString, destination: url).font(.caption) }
                    }
                }
            }
            if !run.limitations.isEmpty {
                Section("Limitations") { ForEach(Array(Set(run.limitations)).sorted(), id: \.self) { Text($0).font(.footnote) } }
            }
        }.navigationTitle("Research evidence").navigationBarTitleDisplayMode(.inline)
    }
}
