import Foundation

enum SearchKeyKind {
    case tavily, exa
    static func detect(_ input: String) -> Self? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 20, !key.contains(where: \.isWhitespace) else { return nil }
        if key.lowercased().hasPrefix("tvly-") { return .tavily }
        if key.lowercased().hasPrefix("exa-") || UUID(uuidString: key) != nil { return .exa }
        return nil
    }
}
