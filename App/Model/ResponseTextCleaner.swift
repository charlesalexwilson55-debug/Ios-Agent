import Foundation

/// Removes model protocol wrappers from visible prose without changing code
/// examples such as HTML or XML inside fenced blocks.
enum ResponseTextCleaner {
    /// Block markers are not interpreted by SwiftUI's inline Markdown parser.
    /// Preserve inline emphasis and mathematical stars; convert only list/headings.
    static func displayProse(_ text: String) -> String {
        let formatted = text.components(separatedBy: "\n").map { line in
            let bullet = line.replacingOccurrences(of: #"^(\s*)[-*]\s+"#, with: "$1• ", options: .regularExpression)
            return bullet.replacingOccurrences(of: #"^\s*#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)
        }.joined(separator: "\n")
        // Preserve explicit Markdown links and inline code. Bare web addresses
        // become readable, tappable site labels rather than long raw URLs.
        let protected = try! NSRegularExpression(pattern: #"\[[^\]]*\]\([^\n]*?\)|`[^`]*`"#)
        let urls = try! NSRegularExpression(pattern: #"https?://[^\s<>\]]+"#)
        let value = formatted as NSString
        let range = NSRange(location: 0, length: value.length)
        let protectedRanges = protected.matches(in: formatted, range: range).map(\.range)
        var result = formatted
        for match in urls.matches(in: formatted, range: range).reversed() {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let raw = value.substring(with: match.range)
            let address = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)"))
            guard let url = URL(string: address), let host = url.host else { continue }
            let label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if let swiftRange = Range(match.range, in: result) {
                result.replaceSubrange(swiftRange, with: "[\(label)](\(address))" + raw.dropFirst(address.count))
            }
        }
        // Em dashes used as prose separators become paragraph spacing. Do not
        // alter inline code, link destinations, maths or fenced content.
        let protectedResult = protected.matches(in: result, range: NSRange(result.startIndex..., in: result)).map(\.range)
        let dashes = try! NSRegularExpression(pattern: #"\s*—\s*"#)
        for match in dashes.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard !protectedResult.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: "\n\n")
        }
        return result
    }

    private static let wrapper = try! NSRegularExpression(
        pattern: #"(?i)</?\s*(?:answer|final|response|output|question)(?:\s*\?\s*=\s*(?:true|false))?(?:\s+[^<>]*?)?\s*>"#
    )

    static func clean(_ raw: String, streaming: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some local models return a complete JavaScript function without its
        // Markdown fence. Reuse the copyable code renderer without editing code
        // or guessing that ordinary prose is a programming language.
        if !streaming, trimmed.range(of: #"(?s)^(?:async\s+)?function\s+[$\p{L}_][$\p{L}\p{N}_]*\s*\([^\n]*\)\s*\{.*\}\s*;?$"#,
                                     options: .regularExpression) != nil {
            return "```javascript\n\(trimmed)\n```"
        }
        var result = ""
        var inFence = false
        for line in raw.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                result += line + "\n"
                continue
            }
            if inFence {
                result += line + "\n"
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            result += wrapper.stringByReplacingMatches(in: line, range: range, withTemplate: "") + "\n"
        }
        if result.hasSuffix("\n") { result.removeLast() }
        if streaming, let start = result.range(of: #"<\s*/?\s*(?:answ|ques|fin|resp|outp)[^>\n]*$"#,
                                               options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(start)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
