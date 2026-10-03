import Foundation

/// User-facing outcomes separate a failed read from an absence of evidence.
/// Internal graph counts and rule scores remain in the inspectable archive.
enum ResearchPresentation {
    static func empty(_ findings: ResearchEngine.Findings, hasCandidates: Bool) -> String {
        if hasCandidates {
            return "I found possible sources, but couldn't read enough reliable information to confirm which profile matches. You can inspect the sources or choose a profile to keep researching."
        }
        if findings.limitations.contains(where: { $0.lowercased().contains("minor") }) {
            return "Some results concerned minors and weren't used to build a personal profile. I haven't confirmed a suitable matching public source."
        }
        let failed = (findings.run?.searchesLog.contains { $0.status == "failed" } ?? false) || !findings.limitations.isEmpty
        if failed {
            return "This search couldn't read enough useful results to confirm a match. Some searches or pages were unavailable. That doesn't mean there are no relevant results. The search history is saved so you can continue it."
        }
        return "I haven't confirmed a matching source yet. The pages I could read didn't contain enough information linking the name to your details. I haven't ruled out other results, and the search history is saved."
    }

    static func closing(_ findings: ResearchEngine.Findings, selected: Bool) -> String {
        let identity = selected
            ? "This report follows the profile you selected. Other possible matches stay separate."
            : "These sources mention the name you gave me. I kept different profiles separate wherever their details didn't line up."
        let limit = findings.stopReason.lowercased().contains("budget")
            ? " I paused at this search batch's limit; its progress is saved."
            : ""
        let access = findings.limitations.isEmpty ? "" : " Some searches or pages were unavailable, so this report may be incomplete."
        return identity + limit + access + "\n\nSource links and search history are in Settings → Research Archive."
    }
}
