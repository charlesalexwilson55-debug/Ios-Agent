import Foundation

@main struct ArtifactTests {
    static func main() throws {
        let files = [VirtualFile(path: "index.html", content: "<h1>Hello</h1>"),
                     VirtualFile(path: "assets/main.js", content: "console.log('hi')")]
        try FileProject.validate(files)
        for path in ["../escape", "/absolute", "a/../../escape", "a\\evil", "a//b", "a/./b"] {
            do { try FileProject.validate([VirtualFile(path: path, content: "x")]); fatalError("Accepted \(path)") }
            catch {}
        }
        do { try FileProject.validate([files[0], files[0]]); fatalError("Accepted duplicate paths") } catch {}
        let parsed = ArtifactParser.files(from: "```html filename=index.html\n<h1>Hi</h1>\n```\n```css filename=style.css\nh1 { color: red }\n```", complete: true)
        precondition(parsed.map(\.path) == ["index.html", "style.css"])
        precondition(ArtifactParser.files(from: "```html\nunfinished", complete: true).isEmpty)
        precondition(ArtifactParser.files(from: "```html\nhello\n```", complete: false).isEmpty)
        // A file card exists before its first code token arrives.
        let opening = MessageSegment.parse("```swift filename=Main.swift\n")
        guard let openingSegment = opening.first,
              case .code(let emptyBlock) = openingSegment.kind else { fatalError("Missing early file card") }
        precondition(emptyBlock.path == "Main.swift" && !emptyBlock.isClosed && emptyBlock.code.isEmpty)
        let writing = MessageSegment.parse("Here are the files.\n```html filename=index.html\n<h1>Hello</h1>\n```\n```css filename=style.css\nbody {\n    color: red;")
        guard writing.count == 3,
              case .code(let firstBlock) = writing[1].kind,
              case .code(let secondBlock) = writing[2].kind else { fatalError("Missing streaming cards") }
        precondition(firstBlock.path == "index.html" && firstBlock.isClosed)
        precondition(secondBlock.path == "style.css" && !secondBlock.isClosed)
        precondition(secondBlock.code == "body {\n    color: red;", "Copy and download must preserve indentation")
        let finished = MessageSegment.parse("Here are the files.\n```html filename=index.html\n<h1>Hello</h1>\n```\n```css filename=style.css\nbody {\n    color: red;\n}\n```")
        precondition(writing.map(\.id) == finished.map(\.id), "Cards must keep their identity when writing finishes")
        guard case .code(let completedBlock) = finished[2].kind else { fatalError("Missing completed card") }
        precondition(completedBlock.isClosed && completedBlock.path == secondBlock.path)
        guard let unnamedSegment = MessageSegment.parse("```python\nprint('hello')").first,
              case .code(let unnamed) = unnamedSegment.kind else { fatalError("Missing unnamed card") }
        precondition(unnamed.path == "file-1.py")
        guard let unsafeSegment = MessageSegment.parse("```swift filename=../escape.swift\nlet x = 1").first,
              case .code(let unsafe) = unsafeSegment.kind else { fatalError("Missing safe fallback card") }
        precondition(unsafe.path == "file-1.txt")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try FileProject.save(title: "Fixture", files: files, root: root)
        let saved = try String(contentsOf: root.appendingPathComponent(project.id).appendingPathComponent("assets/main.js"), encoding: .utf8)
        precondition(saved == files[1].content)
        precondition(project.entryPoint?.lastPathComponent == "index.html")
        try FileProject.archive(project).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(ModelWheel.index(rotation: -359, count: 4) == 0)
        precondition(ModelWheel.index(rotation: 90, count: 4) == 3)
        precondition(ModelWheel.index(rotation: -90, count: 4) == 1)
        precondition(ModelWheel.index(rotation: 25, count: 0) == nil)
        print("Artifact paths, parsing, persistence, ZIP generation and wheel wrapping passed")
    }
}
