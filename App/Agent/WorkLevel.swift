import Foundation

/// How hard Conduit works on each request, from the plus menu's slider.
///
/// Each step up writes one more draft of an answer: Ultra writes five, from
/// very simple to in depth (or, for code, five different solutions), picks
/// the best to show, and keeps the rest a tap away. Phone actions are never
/// repeated; higher levels give those more steps and more thinking instead.
enum WorkLevel: Int, Codable, CaseIterable, Identifiable {
    case normal = 0, plus, extra, max, ultra

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .plus: "Plus"
        case .extra: "Extra"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }

    /// Answers written for a question.
    var drafts: Int { rawValue + 1 }

    /// Tool calls allowed per request.
    var toolSteps: Int {
        switch self {
        case .normal: return 6
        case .plus: return 8
        case .extra: return 10
        case .max: return 12
        case .ultra: return 15
        }
    }

    /// Max and Ultra always think before the first draft; lower levels
    /// follow the Think switch.
    var forcesThinking: Bool { self >= .max }

    var researchBudget: ResearchEngine.Budget {
        switch self {
        case .normal, .plus: return .normal
        case .extra, .max: return .hard
        case .ultra: return .ultra
        }
    }

    var summary: String {
        switch self {
        case .normal: "One answer, at the usual pace."
        case .plus: "Two drafts; the best is shown."
        case .extra: "Three drafts, simple to detailed."
        case .max: "Four drafts, always thinks first."
        case .ultra: "Five drafts, thinks first, researches the most. Slowest."
        }
    }
}

extension WorkLevel: Comparable {
    static func < (lhs: WorkLevel, rhs: WorkLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Automatic configuration: picks the level, Think and Research from what
/// the request looks like.
enum AutoConfig {
    struct Choice: Equatable {
        let level: WorkLevel
        let thinking: Bool
        let research: Bool
    }

    private static let codeWords: Set<String> = [
        "code", "coding", "function", "script", "program", "programming", "implement", "bug",
        "debug", "regex", "sql", "swift", "swiftui", "python", "javascript", "typescript", "java",
        "kotlin", "rust", "html", "css", "algorithm", "api", "compile", "compiler", "json",
        "class", "method", "refactor", "unittest", "bash", "powershell", "excel", "formula",
    ]

    private static let mathsWords: Set<String> = [
        "calculate", "calculation", "solve", "equation", "integral", "derivative", "probability",
        "percent", "percentage", "sum", "average", "mean", "median", "factor", "prime", "algebra",
        "geometry", "area", "volume", "convert", "interest", "maths", "math",
    ]

    private static let instructionPhrases = [
        "how do i", "how do you", "how to", "how can i", "step by step", "steps to", "guide",
        "instructions", "explain", "teach me", "walk me through", "what's the best way",
        "whats the best way", "recipe", "plan for", "make a plan", "tips",
    ]

    private static let writingPhrases = [
        "write a", "write an", "write me", "draft a", "essay", "story", "poem", "cover letter",
        "speech", "caption", "bio for", "summary of", "summarise", "summarize", "rewrite",
    ]

    /// Research only when asked for, not whenever the word appears: "my
    /// research paper is due" is not a request to research anything.
    private static let researchOpenings = [
        "research ", "deep dive", "dig into", "find out everything", "find everything about",
    ]
    private static let researchPhrases = [
        "can you research ", "could you research ", "please research ", "everything you can find",
        "find out everything about",
    ]

    static func choose(for request: String, isPhoneTask: Bool) -> Choice {
        let lower = request.lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        if researchOpenings.contains(where: { lower.hasPrefix($0) })
            || researchPhrases.contains(where: { lower.contains($0) }) {
            return Choice(level: .extra, thinking: false, research: true)
        }
        if isPhoneTask {
            return Choice(level: .normal, thinking: false, research: false)
        }
        if !codeWords.isDisjoint(with: words) || request.contains("```") {
            return Choice(level: .extra, thinking: true, research: false)
        }
        let hasSums = lower.range(of: #"\d\s*[-+*/x^%]\s*\d"#, options: .regularExpression) != nil
        if hasSums || !mathsWords.isDisjoint(with: words) {
            return Choice(level: .plus, thinking: true, research: false)
        }
        if instructionPhrases.contains(where: { lower.contains($0) }) {
            return Choice(level: .extra, thinking: false, research: false)
        }
        if writingPhrases.contains(where: { lower.contains($0) }) {
            return Choice(level: .extra, thinking: false, research: false)
        }
        if words.count <= 8 {
            return Choice(level: .normal, thinking: false, research: false)
        }
        return Choice(level: .plus, thinking: false, research: false)
    }
}

/// How the extra drafts differ from each other, and how the best is chosen.
enum DraftPlanner {

    struct Style {
        let label: String
        let instruction: String
    }

    static let firstLabel = "Standard"

    /// For drafts two onward, in order. The first draft is the model's
    /// ordinary answer.
    private static let answerStyles = [
        Style(label: "Simple", instruction: "Make this version very simple and short: plain words and "
            + "only the essentials, as if for a complete beginner."),
        Style(label: "In depth", instruction: "Make this version thorough and expert: more depth, the "
            + "reasons behind each point, and the useful details and caveats."),
        Style(label: "Step by step", instruction: "Make this version a clear numbered list of steps or "
            + "points that is easy to follow."),
        Style(label: "Another angle", instruction: "Make this version take a different angle from the "
            + "obvious answer, with a practical example."),
    ]

    private static let codeStyles = [
        Style(label: "Simplest", instruction: "Write the simplest correct solution, as short as it can "
            + "be while staying readable."),
        Style(label: "Robust", instruction: "Write a robust solution that handles edge cases and bad "
            + "input, with brief comments."),
        Style(label: "Fastest", instruction: "Write the most efficient solution you can, and state its "
            + "time complexity in one line."),
        Style(label: "Other approach", instruction: "Solve it with a different approach or technique "
            + "from the obvious one."),
    ]

    private static let codeMarkers = [
        "```", "func ", "def ", "function ", "class ", "import ", "#include", "select ", "=> ",
    ]

    static func isCode(request: String, answer: String) -> Bool {
        if codeMarkers.contains(where: { answer.contains($0) }) { return true }
        let words = Set(request.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        return words.contains("code") || words.contains("function") || words.contains("script")
            || words.contains("program")
    }

    static func styles(extraDrafts: Int, code: Bool) -> [Style] {
        let pool = code ? codeStyles : answerStyles
        return Array(pool.prefix(extraDrafts))
    }

    static func instruction(style: String) -> String {
        "Answer my last message again, as a separate version. \(style) Reply with the answer only, "
            + "without mentioning other versions."
    }

    /// Drafts longer than this are cut short in the comparison prompt, to
    /// keep it within the phone's memory.
    private static let judgeDraftLimit = 1_500

    static func judgePrompt(drafts: [String], code: Bool) -> String {
        let listing = drafts.enumerated().map { index, draft -> String in
            let text = draft.count > judgeDraftLimit ? String(draft.prefix(judgeDraftLimit)) + " [...]" : draft
            return "Answer \(index + 1):\n\(text)"
        }
        .joined(separator: "\n\n")
        let criteria = code
            ? "Judge whether the code is correct and would run first, then clarity."
            : "Judge correctness first, then how well it fits what I asked, then clarity."
        return "Here are \(drafts.count) answers to my last message.\n\n\(listing)\n\n"
            + "Which answer serves my message best? \(criteria) Reply with only the number."
    }

    /// The chosen draft's index, from the model's reply. The first draft
    /// when the reply names none.
    static func pick(from reply: String, count: Int) -> Int {
        guard let range = reply.range(of: #"\d+"#, options: .regularExpression),
              let number = Int(reply[range]), (1...count).contains(number)
        else { return 0 }
        return number - 1
    }
}
