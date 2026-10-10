import Foundation

@main struct SemanticTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let vocabURL = root.appendingPathComponent("minilm-vocab.txt")
        let tokenizer = MiniLMTokenizer(vocabularyText: try String(contentsOf: vocabURL, encoding: .utf8))
        let tokens = tokenizer.encode("Hello, WORLD!")
        precondition(Array(tokens.ids.prefix(6)) == [101, 7592, 1010, 2088, 999, 102])
        precondition(tokens.mask.reduce(0, +) == 6 && tokens.ids.count == 256)
        precondition(tokenizer.encode("café").ids == tokenizer.encode("cafe").ids)
        let long = tokenizer.encode(String(repeating: "hello ", count: 400))
        precondition(long.ids.count == 256 && long.ids.last == 102 && long.mask.allSatisfy { $0 == 1 })
        let search = SemanticSearch()
        try await search.load(modelURL: root.appendingPathComponent("MiniLM.mlpackage"), vocabularyURL: vocabURL)
        let query = try await search.embedding("A teacher offers private tutoring in Melbourne.")
        let related = try await search.embedding("An educator provides individual lessons to students.")
        let unrelated = try await search.embedding("A spacecraft orbits Jupiter and measures cosmic radiation.")
        precondition(query.count == 384)
        precondition(abs(SemanticSearch.similarity(query, query) - 1) < 0.0001)
        precondition(SemanticSearch.similarity(query, related) > SemanticSearch.similarity(query, unrelated) + 0.1)
        let order = try await search.rankedIndices(query: "Private tutoring lessons", passages: ["Jupiter spacecraft orbit", "An educator helps students learn"])
        precondition(order == [1, 0])
        let request = "James Fagan, mid 30s, melbourne, cheltenham, sandringham, male, teacher, tutor"
        let plan = ResearchPlanner.make(request: request, reply: "")
        precondition(Set(plan.clues.map { $0.lowercased() }) == Set(["melbourne", "cheltenham", "sandringham"]))
        precondition(plan.queries.contains { $0.contains("tutor") && $0.contains("cheltenham") })
        precondition(!plan.hasSubject(in: "Another Person teaches in Melbourne"))
        let page = String(repeating: "Unrelated space news. ", count: 600) + "James Fagan is a teacher in Melbourne. " + String(repeating: "Tutoring supports students with individual lessons. ", count: 200)
        let excerpt = try await search.excerpt(page, plan: plan)
        precondition(excerpt.count <= 7000 && excerpt.contains("James Fagan"))
        print("MiniLM tokenizer, inference, passage ranking and compact research clues passed")
    }
}
