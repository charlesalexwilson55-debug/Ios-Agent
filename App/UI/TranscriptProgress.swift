import Foundation

/// Progress belongs to the current turn, even when archived research has unfinished steps.
enum TranscriptProgress {
    struct Row {
        var isUser = false
        var isTool = false
        var isStreaming = false
        var hasAnswer = false
        var runningTitles: [String] = []
    }

    static func label(rows: [Row], thinking: Bool) -> String {
        let start = rows.lastIndex(where: { $0.isUser }).map { $0 + 1 } ?? 0
        let current = rows.dropFirst(start)
        if let last = current.last, last.isStreaming && last.hasAnswer { return "Typing" }
        if let title = current.reversed().compactMap({ $0.runningTitles.last }).first?.lowercased() {
            if title.contains("search") || title.contains("research") { return "Researching" }
            if title.contains("read") || title.contains("extract") { return "Reading" }
            if title.contains("writ") { return "Writing" }
            if title.contains("load") { return "Loading" }
            if title.contains("resolv") || title.contains("check") { return "Cross-checking" }
            return "Planning"
        }
        if current.last?.isTool == true { return "Routing" }
        return thinking ? "Thinking" : "Working"
    }
}
