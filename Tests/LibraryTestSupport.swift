import Foundation

// Production import, OCR, photos and SQLite are used. Only unrelated logging
// and HTML helpers are substituted so this test target has no LLM dependency.
enum Diagnostics { static func log(_ text: String) {} }
enum HTMLText {
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
    static func decodeEntities(_ text: String) -> String { text }
}
