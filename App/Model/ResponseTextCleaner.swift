import Foundation

/// Removes model protocol wrappers from visible prose without changing code
/// examples such as HTML or XML inside fenced blocks.
enum ResponseTextCleaner {
    private static let wrapper = try! NSRegularExpression(
        pattern: #"(?i)</?\s*(?:answer|final|response|output|question)(?:\s*\?\s*=\s*(?:true|false))?(?:\s+[^<>]*?)?\s*>"#
    )

    static func clean(_ raw: String, streaming: Bool = false) -> String {
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
