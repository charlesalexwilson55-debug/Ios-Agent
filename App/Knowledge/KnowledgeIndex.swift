import Accelerate
import Foundation
import NaturalLanguage
import SQLite3

/// The local search index behind Libraries, the memory bank and the profile.
///
/// Text is cut into overlapping passages and stored twice: in a SQLite FTS5
/// table for keyword search (BM25), and as on-device sentence embeddings for
/// meaning search. A query runs both and merges the rankings, so a question
/// finds passages that use different words as well as ones that match. Nothing
/// leaves the phone, and it all works offline.
actor KnowledgeIndex {
    static let shared = KnowledgeIndex()

    enum Source: String, Codable, CaseIterable {
        case library, memory, profile
    }

    struct Document: Identifiable, Hashable, Sendable {
        let id: String
        let source: Source
        /// A library id, a chat id, or "profile".
        let collection: String
        let title: String
        let added: Date
        let characters: Int
        let passages: Int
    }

    struct Hit: Identifiable, Hashable, Sendable {
        var id: Int64 { passage }
        let passage: Int64
        let documentID: String
        let source: Source
        let collection: String
        let title: String
        let text: String
        /// Whether the passage shares a real word with the query.
        let keywordMatch: Bool
        /// Cosine similarity of meaning, or 0 when embeddings are unavailable.
        let similarity: Float
        let score: Double
    }

    private static let passageLength = 900
    private static let passageOverlap = 150

    private var db: OpaquePointer?
    private var ready = false
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    /// Vectors held in memory after the first search, per source.
    private var vectorCache: [Source: [(passage: Int64, vector: [Float])]] = [:]

    private init() {}

    // MARK: - Setup

    private static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("index.sqlite")
    }

    private func open() throws {
        guard !ready else { return }
        guard sqlite3_open(Self.databaseURL.path, &db) == SQLITE_OK else {
            throw IndexError.database("could not open the index")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS documents(
                id TEXT PRIMARY KEY, source TEXT NOT NULL, collection TEXT NOT NULL,
                title TEXT NOT NULL, added REAL NOT NULL, characters INTEGER NOT NULL,
                passages INTEGER NOT NULL)
            """)
        try execute("CREATE INDEX IF NOT EXISTS documents_collection ON documents(collection)")
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(
                text, document UNINDEXED, tokenize = 'porter unicode61')
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS vectors(
                passage INTEGER PRIMARY KEY, document TEXT NOT NULL, source TEXT NOT NULL,
                vector BLOB NOT NULL)
            """)
        try execute("CREATE INDEX IF NOT EXISTS vectors_document ON vectors(document)")
        ready = true
    }

    enum IndexError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self {
            case .database(let why): "The knowledge index failed: \(why)."
            }
        }
    }

    // MARK: - Writing

    /// Replaces a document's text in the index. Returns the passage count.
    @discardableResult
    func add(id: String, source: Source, collection: String, title: String, text: String) throws -> Int {
        try open()
        try removeRows(document: id)
        let passages = Self.passages(from: text)
        try execute("BEGIN")
        do {
            for passage in passages {
                let rowid = try insertPassage(passage, document: id)
                if let vector = vector(for: passage) {
                    try insertVector(vector, passage: rowid, document: id, source: source)
                }
            }
            try run("""
                INSERT OR REPLACE INTO documents(id, source, collection, title, added, characters, passages)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(source.rawValue), .text(collection), .text(title),
                      .real(Date().timeIntervalSince1970), .int(Int64(text.count)), .int(Int64(passages.count))])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        vectorCache[source] = nil
        return passages.count
    }

    func remove(document id: String) throws {
        try open()
        try removeRows(document: id)
        try run("DELETE FROM documents WHERE id = ?", [.text(id)])
        vectorCache = [:]
    }

    func remove(collection: String) throws {
        try open()
        for document in try documents(collection: collection) {
            try removeRows(document: document.id)
        }
        try run("DELETE FROM documents WHERE collection = ?", [.text(collection)])
        vectorCache = [:]
    }

    private func removeRows(document id: String) throws {
        try run("DELETE FROM passages WHERE document = ?", [.text(id)])
        try run("DELETE FROM vectors WHERE document = ?", [.text(id)])
    }

    // MARK: - Reading

    func documents(collection: String) throws -> [Document] {
        try open()
        return try query("""
            SELECT id, source, collection, title, added, characters, passages
            FROM documents WHERE collection = ? ORDER BY added DESC
            """, [.text(collection)]).map(Self.document)
    }

    func documents(source: Source) throws -> [Document] {
        try open()
        return try query("""
            SELECT id, source, collection, title, added, characters, passages
            FROM documents WHERE source = ? ORDER BY added DESC
            """, [.text(source.rawValue)]).map(Self.document)
    }

    /// The best passages for a query from the given sources, limited to the
    /// given collections when set.
    func search(_ text: String, sources: Set<Source>, collections: Set<String>? = nil,
                limit: Int = 6) throws -> [Hit] {
        try open()
        guard !sources.isEmpty else { return [] }
        let terms = Self.searchTerms(text)
        var keywordRanks: [Int64: Int] = [:]
        if !terms.isEmpty {
            let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
            let rows = try query("""
                SELECT passages.rowid FROM passages JOIN documents d ON d.id = passages.document
                WHERE passages MATCH ? AND d.source IN (\(sources.map { "'\($0.rawValue)'" }.joined(separator: ",")))
                ORDER BY bm25(passages) LIMIT 60
                """, [.text(match)])
            for (rank, row) in rows.enumerated() {
                if case .int(let id) = row[0] { keywordRanks[id] = rank }
            }
        }

        var similarities: [Int64: Float] = [:]
        var meaningRanks: [Int64: Int] = [:]
        if let queryVector = vector(for: text) {
            var scored: [(Int64, Float)] = []
            for source in sources {
                for item in try cachedVectors(source) {
                    scored.append((item.passage, Self.cosine(queryVector, item.vector)))
                }
            }
            scored.sort { $0.1 > $1.1 }
            for (rank, item) in scored.prefix(60).enumerated() {
                similarities[item.0] = item.1
                meaningRanks[item.0] = rank
            }
        }

        // Reciprocal rank fusion: a passage near the top of either list does
        // well, and one near the top of both does best.
        var fused: [Int64: Double] = [:]
        for (id, rank) in keywordRanks { fused[id, default: 0] += 1 / Double(60 + rank) }
        for (id, rank) in meaningRanks where (similarities[id] ?? 0) >= 0.35 {
            fused[id, default: 0] += 1 / Double(60 + rank)
        }
        let ranked = fused.sorted { $0.value > $1.value }

        var hits: [Hit] = []
        for (id, score) in ranked {
            guard hits.count < limit else { break }
            let rows = try query("""
                SELECT p.text, d.id, d.source, d.collection, d.title
                FROM passages p JOIN documents d ON d.id = p.document WHERE p.rowid = ?
                """, [.int(id)])
            guard let row = rows.first,
                  case .text(let passage) = row[0], case .text(let documentID) = row[1],
                  case .text(let sourceRaw) = row[2], case .text(let collection) = row[3],
                  case .text(let title) = row[4],
                  let source = Source(rawValue: sourceRaw)
            else { continue }
            if let collections, !collections.contains(collection) { continue }
            hits.append(Hit(passage: id, documentID: documentID, source: source, collection: collection,
                            title: title, text: passage, keywordMatch: keywordRanks[id] != nil,
                            similarity: similarities[id] ?? 0, score: score))
        }
        return hits
    }

    private func cachedVectors(_ source: Source) throws -> [(passage: Int64, vector: [Float])] {
        if let cached = vectorCache[source] { return cached }
        let rows = try query("SELECT passage, vector FROM vectors WHERE source = ?", [.text(source.rawValue)])
        let vectors: [(passage: Int64, vector: [Float])] = rows.compactMap { row in
            guard case .int(let id) = row[0], case .blob(let data) = row[1] else { return nil }
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return (passage: id, vector: floats)
        }
        vectorCache[source] = vectors
        return vectors
    }

    // MARK: - Text

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "were", "be",
        "it", "this", "that", "with", "as", "at", "by", "from", "what", "who", "how", "why", "when",
        "where", "which", "do", "does", "did", "i", "me", "my", "you", "your", "can", "could", "would",
        "should", "about", "tell", "please", "there", "their", "them", "they", "we", "our", "us",
        "have", "has", "had", "will", "just", "so", "if", "not", "no", "yes", "any", "some",
    ]

    static func searchTerms(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) && seen.insert($0).inserted }
            .prefix(16)
            .map { $0 }
    }

    /// Overlapping passages, broken at paragraph or sentence ends where
    /// possible.
    static func passages(from text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > passageLength else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        var result: [String] = []
        var start = 0
        while start < characters.count {
            var end = min(start + passageLength, characters.count)
            if end < characters.count {
                // Prefer to stop at a blank line, then a sentence end, in the
                // last third of the passage.
                let floor = start + passageLength * 2 / 3
                var cut: Int?
                var index = end - 1
                while index > floor {
                    if characters[index] == "\n", characters[index - 1] == "\n" { cut = index; break }
                    index -= 1
                }
                if cut == nil {
                    index = end - 1
                    while index > floor {
                        if ".!?".contains(characters[index]), characters[index + 1] == " " {
                            cut = index + 1
                            break
                        }
                        index -= 1
                    }
                }
                if let cut { end = cut }
            }
            let passage = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty { result.append(passage) }
            if end >= characters.count { break }
            start = max(end - passageOverlap, start + 1)
        }
        return result
    }

    private func vector(for text: String) -> [Float]? {
        guard let embedding else { return nil }
        let sample = String(text.prefix(1_000))
        guard let values = embedding.vector(for: sample), !values.isEmpty else { return nil }
        return values.map { Float($0) }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    // MARK: - SQLite

    private enum Value {
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw IndexError.database(text)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.database(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw IndexError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ values: [Value]) throws -> [[Value]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw IndexError.database(String(cString: sqlite3_errmsg(db)))
            }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT:
                    row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    let text = sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                    row.append(.text(text))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func insertPassage(_ text: String, document: String) throws -> Int64 {
        try run("INSERT INTO passages(text, document) VALUES(?, ?)", [.text(text), .text(document)])
        return sqlite3_last_insert_rowid(db)
    }

    private func insertVector(_ vector: [Float], passage: Int64, document: String, source: Source) throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try run("INSERT OR REPLACE INTO vectors(passage, document, source, vector) VALUES(?, ?, ?, ?)",
                [.int(passage), .text(document), .text(source.rawValue), .blob(data)])
    }

    private static func document(_ row: [Value]) -> Document {
        func text(_ index: Int) -> String {
            if case .text(let value) = row[index] { return value }
            return ""
        }
        func number(_ index: Int) -> Int {
            if case .int(let value) = row[index] { return Int(value) }
            return 0
        }
        var added = Date()
        if case .real(let seconds) = row[4] { added = Date(timeIntervalSince1970: seconds) }
        return Document(id: text(0), source: Source(rawValue: text(1)) ?? .library, collection: text(2),
                        title: text(3), added: added, characters: number(5), passages: number(6))
    }
}
