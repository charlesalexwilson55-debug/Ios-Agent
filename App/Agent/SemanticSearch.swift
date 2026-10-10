import Foundation
import CoreML

/// BERT uncased WordPiece. Padding and truncation match the exported model.
struct MiniLMTokenizer {
    let vocabulary: [String: Int]
    init(vocabularyText: String) {
        vocabulary = Dictionary(uniqueKeysWithValues: vocabularyText.components(separatedBy: "\n")
            .enumerated().filter { !$0.element.isEmpty }.map { ($0.element, $0.offset) })
    }

    func encode(_ text: String) -> (ids: [Int], mask: [Int]) {
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var basic: [String] = [], word = ""
        func flush() { if !word.isEmpty { basic.append(word); word = "" } }
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush() }
            else if CharacterSet.controlCharacters.contains(scalar) { continue }
            else if CharacterSet.punctuationCharacters.contains(scalar)
                || (33...47).contains(value) || (58...64).contains(value)
                || (91...96).contains(value) || (123...126).contains(value)
                || (0x4E00...0x9FFF).contains(value) {
                flush(); basic.append(String(scalar))
            } else { word.unicodeScalars.append(scalar) }
        }
        flush()
        var ids = [vocabulary["[CLS]"] ?? 101]
        for token in basic {
            let characters = Array(token)
            var pieces: [Int] = [], start = 0
            if characters.count <= 100 {
                while start < characters.count {
                    var end = characters.count, found: Int?
                    while end > start {
                        let piece = (start == 0 ? "" : "##") + String(characters[start..<end])
                        if let id = vocabulary[piece] { found = id; break }
                        end -= 1
                    }
                    guard let found else { pieces = [vocabulary["[UNK]"] ?? 100]; break }
                    pieces.append(found); start = end
                }
            } else { pieces = [vocabulary["[UNK]"] ?? 100] }
            ids += pieces.prefix(max(0, 255 - ids.count))
            if ids.count >= 255 { break }
        }
        ids.append(vocabulary["[SEP]"] ?? 102)
        let mask = Array(repeating: 1, count: ids.count) + Array(repeating: 0, count: 256 - ids.count)
        ids += Array(repeating: vocabulary["[PAD]"] ?? 0, count: 256 - ids.count)
        return (ids, mask)
    }
}

/// Embedding inference is isolated from the UI and never merges candidates.
actor SemanticSearch {
    static let shared = SemanticSearch()
    private var model: MLModel?
    private var tokenizer: MiniLMTokenizer?
    private var cache: [String: [Double]] = [:]

    enum Failure: Error { case missingResources, invalidEmbedding }

    func load(modelURL: URL, vocabularyURL: URL) throws {
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        tokenizer = MiniLMTokenizer(vocabularyText: try String(contentsOf: vocabularyURL, encoding: .utf8))
        cache.removeAll()
    }

    func embedding(_ text: String) throws -> [Double] {
        try Task.checkCancellation()
        if let cached = cache[text] { return cached }
        if model == nil {
            guard let url = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc"),
                  let vocab = Bundle.main.url(forResource: "minilm-vocab", withExtension: "txt") else { throw Failure.missingResources }
            try load(modelURL: url, vocabularyURL: vocab)
        }
        guard let model, let tokenizer else { throw Failure.missingResources }
        let tokens = tokenizer.encode(text)
        func array(_ values: [Int]) throws -> MLMultiArray {
            let result = try MLMultiArray(shape: [1, 256], dataType: .int32)
            for index in values.indices { result[index] = NSNumber(value: values[index]) }
            return result
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: try array(tokens.ids)),
            "attention_mask": MLFeatureValue(multiArray: try array(tokens.mask)),
            "token_type_ids": MLFeatureValue(multiArray: try array(Array(repeating: 0, count: 256)))
        ])
        let prediction = try model.prediction(from: input)
        guard let output = prediction.featureValue(for: "div_1")?.multiArrayValue, output.count == 384 else { throw Failure.invalidEmbedding }
        let vector = (0..<output.count).map { output[$0].doubleValue }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0, vector.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
        let normalized = vector.map { $0 / norm }
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[text] = normalized
        return normalized
    }

    static func similarity(_ first: [Double], _ second: [Double]) -> Double {
        zip(first, second).reduce(0) { $0 + $1.0 * $1.1 }
    }

    func rankedIndices(query: String, passages: [String]) throws -> [Int] {
        let vector = try embedding(query)
        var scores: [(index: Int, score: Double)] = []
        for (index, passage) in passages.prefix(24).enumerated() {
            scores.append((index, Self.similarity(vector, try embedding(String(passage.prefix(1200))))))
        }
        return scores.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }.map(\.index)
            + Array(passages.indices.dropFirst(24))
    }

    /// Preserve name-centred text before adding ranked, unmodified passages.
    func excerpt(_ text: String, plan: ResearchPlan, limit: Int = 7000) throws -> String {
        if text.count <= limit { return text }
        let query = try embedding(plan.request)
        let characters = Array(text.prefix(60_000))
        var passages: [(index: Int, text: String, score: Double)] = []
        // Evenly sample long pages, bounded to 32 predictions per source.
        let chunks = max(1, (characters.count + 799) / 800)
        let indices = Set((0..<min(chunks, 32)).map { $0 * chunks / min(chunks, 32) }).sorted()
        for index in indices {
            try Task.checkCancellation()
            let start = index * 800
            let passage = String(characters[start..<min(start + 1000, characters.count)])
            passages.append((index, passage, Self.similarity(query, try embedding(passage))))
        }
        let anchor = plan.excerpt(text, limit: limit / 2)
        var remaining = limit - anchor.count - 2
        var chosen: [(index: Int, text: String)] = []
        for passage in passages.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
            guard passage.text.count + 2 <= remaining, !anchor.contains(passage.text) else { continue }
            chosen.append((passage.index, passage.text)); remaining -= passage.text.count + 2
        }
        return ([anchor] + chosen.sorted { $0.index < $1.index }.map(\.text)).joined(separator: "\n\n")
    }
}
