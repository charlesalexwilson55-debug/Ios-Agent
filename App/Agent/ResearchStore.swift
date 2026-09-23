import Foundation
import SQLite3

/// One local transaction per checkpoint. Snapshots enable resumption; normalized
/// record kinds make provenance inspectable without putting model text in memory.
@MainActor final class ResearchStore {
    private var db: OpaquePointer?
    struct StorageError: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func open() throws -> ResearchStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Research", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try ResearchStore(url: root.appendingPathComponent("research.sqlite"))
    }
    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StorageError(message: "Could not open the research archive.") }
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, updated REAL NOT NULL, snapshot BLOB NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS records (run_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(run_id,kind,id));")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    func save(_ run: ResearchRun) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try statement("INSERT OR REPLACE INTO runs(id,updated,snapshot) VALUES(?,?,?);") { stmt in
                bind(run.id.uuidString, at: 1, to: stmt)
                sqlite3_bind_double(stmt, 2, run.updated.timeIntervalSince1970)
                try bind(run, at: 3, to: stmt)
                try step(stmt)
            }
            try statement("DELETE FROM records WHERE run_id=?;") { stmt in bind(run.id.uuidString, at: 1, to: stmt); try step(stmt) }
            func records<T: Encodable & Identifiable>(_ kind: String, _ values: [T]) throws where T.ID: CustomStringConvertible {
                for value in values {
                    try statement("INSERT INTO records(run_id,kind,id,payload) VALUES(?,?,?,?);") { stmt in
                        bind(run.id.uuidString, at: 1, to: stmt); bind(kind, at: 2, to: stmt)
                        bind(value.id.description, at: 3, to: stmt); try bind(value, at: 4, to: stmt); try step(stmt)
                    }
                }
            }
            try records("source", run.graph.sources); try records("entity", run.graph.entities)
            try records("claim", run.graph.claims); try records("evidence", run.graph.evidence)
            try records("relationship", run.graph.relationships); try records("candidate", run.graph.candidates)
            try records("contradiction", run.graph.contradictions); try records("search", run.searchesLog)
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }
    func load(_ id: UUID) throws -> ResearchRun? {
        var result: ResearchRun?
        try statement("SELECT snapshot FROM runs WHERE id=?;") { stmt in
            bind(id.uuidString, at: 1, to: stmt)
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW { result = try decode(stmt, column: 0) }
            else if status != SQLITE_DONE { throw failure() }
        }
        return result
    }
    func list() throws -> [ResearchRun] {
        var runs: [ResearchRun] = []
        try statement("SELECT snapshot FROM runs ORDER BY updated DESC;") { stmt in
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW { runs.append(try decode(stmt, column: 0)); status = sqlite3_step(stmt) }
            if status != SQLITE_DONE { throw failure() }
        }
        return runs
    }
    func delete(_ id: UUID) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for table in ["records", "runs"] {
                try statement("DELETE FROM \(table) WHERE \(table == "runs" ? "id" : "run_id")=?;") { stmt in
                    bind(id.uuidString, at: 1, to: stmt); try step(stmt)
                }
            }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }
    private func decode(_ stmt: OpaquePointer?, column: Int32) throws -> ResearchRun {
        guard let bytes = sqlite3_column_blob(stmt, column) else { throw failure() }
        return try JSONDecoder().decode(ResearchRun.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column))))
    }
    private func statement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }
    private func bind(_ text: String, at index: Int32, to stmt: OpaquePointer?) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind<T: Encodable>(_ value: T, at index: Int32, to stmt: OpaquePointer?) throws {
        let data = try JSONEncoder().encode(value)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func step(_ stmt: OpaquePointer?) throws { if sqlite3_step(stmt) != SQLITE_DONE { throw failure() } }
    private func execute(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() } }
    private func failure() -> StorageError { StorageError(message: "Research archive: " + String(cString: sqlite3_errmsg(db))) }
}
