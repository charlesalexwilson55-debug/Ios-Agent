import Foundation

/// Stable segments keep a file card mounted as its code streams and completes.
struct MessageSegment: Identifiable {
    struct CodeBlock {
        let path: String
        let code: String
        let isClosed: Bool
    }

    enum Kind {
        case prose(String)
        case code(CodeBlock)
    }

    let id: Int
    let kind: Kind

    static func parse(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var header: String?
        var paths: [String] = []

        func push(_ kind: Kind) {
            segments.append(MessageSegment(id: segments.count, kind: kind))
        }
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { push(.prose(joined)) }
            prose.removeAll()
        }
        func flushCode(_ value: String, closed: Bool) {
            let suggested = ArtifactParser.path(for: value, existingPaths: paths)
            let path: String
            if let suggested,
               (try? FileProject.validate([VirtualFile(path: suggested, content: "")])) != nil {
                path = suggested
            } else {
                path = "file-\(paths.count + 1).txt"
            }
            paths.append(path)
            push(.code(CodeBlock(path: path, code: code.joined(separator: "\n"), isClosed: closed)))
            code.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = header {
                    flushCode(open, closed: true)
                    header = nil
                } else {
                    flushProse()
                    header = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if header != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }

        if let open = header { flushCode(open, closed: false) }
        flushProse()
        return segments
    }
}
