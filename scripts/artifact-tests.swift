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
