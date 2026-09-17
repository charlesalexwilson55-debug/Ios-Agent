import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// Turns an imported file into plain text for the knowledge index.
enum TextExtractor {

    enum ExtractError: LocalizedError {
        case unsupported(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let kind): "Conduit cannot read \(kind) files yet."
            case .empty: "No readable text was found in the file."
            }
        }
    }

    /// File types the Libraries importer offers.
    static let importTypes: [UTType] = [
        .pdf, .plainText, .text, .utf8PlainText, .sourceCode, .json, .html, .rtf, .commaSeparatedText,
        .xml, .yaml, .image, .zip,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "xlsx") ?? .data,
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "ini", "toml",
        "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "cs", "go",
        "rs", "rb", "php", "sh", "ps1", "sql", "css", "scss", "m", "mm", "lua", "r", "tex", "srt",
        "vtt", "org", "rst", "gradle", "dart", "scala",
    ]

    /// Largest amount of text kept from one file.
    static let characterLimit = 3_000_000

    static func text(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            text = pdfText(url)
        case "docx":
            text = try officeText(url, parts: { $0 == "word/document.xml" })
        case "pptx":
            text = try officeText(url, parts: { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") })
        case "xlsx":
            text = try officeText(url, parts: { $0 == "xl/sharedStrings.xml" })
        case "zip":
            text = try archiveText(url)
        case "html", "htm":
            text = HTMLText.plain(decode(try Data(contentsOf: url)) ?? "")
        case "rtf":
            let attributed = try NSAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
            text = attributed.string
        case "doc", "pages", "key", "numbers":
            throw ExtractError.unsupported(ext.uppercased())
        default:
            if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
                text = try await imageText(url)
            } else if textExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .text) == true {
                text = decode(try Data(contentsOf: url)) ?? ""
            } else if let decoded = decode(try Data(contentsOf: url)), looksLikeText(decoded) {
                text = decoded
            } else {
                throw ExtractError.unsupported(ext.isEmpty ? "these" : ext.uppercased())
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractError.empty }
        return String(trimmed.prefix(characterLimit))
    }

    /// UTF-8, then UTF-16, then Latin-1.
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func looksLikeText(_ text: String) -> Bool {
        let sample = text.prefix(2_000)
        guard !sample.isEmpty else { return false }
        let control = sample.unicodeScalars.filter {
            $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        return Double(control) / Double(sample.unicodeScalars.count) < 0.02
    }

    // MARK: - Formats

    private static func pdfText(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            pages.append("[Page \(index + 1)]\n\(text)")
        }
        return pages.joined(separator: "\n\n")
    }

    private static func officeText(_ url: URL, parts: (String) -> Bool) throws -> String {
        let zip = try ZipReader(url: url)
        let chosen = zip.entries
            .filter { parts($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return chosen.compactMap { entry in
            zip.text(of: entry).map { xmlText($0) }
        }
        .joined(separator: "\n\n")
    }

    /// Every readable file in an archive, each under its own heading. Used
    /// for data exports and folders of notes.
    static func archiveText(_ url: URL, limit: Int = characterLimit) throws -> String {
        let zip = try ZipReader(url: url)
        var parts: [String] = []
        var total = 0
        for entry in zip.entries where total < limit {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let name = (entry.path as NSString).lastPathComponent
            guard !name.hasPrefix("."), !entry.path.contains("__MACOSX") else { continue }
            var body: String?
            if ["json", "txt", "md", "csv", "xml"].contains(ext) || textExtensions.contains(ext) {
                body = zip.text(of: entry, limit: 5_000_000)
                if ext == "json", let raw = body { body = JSONText.flatten(raw) }
            } else if ext == "html" || ext == "htm" {
                body = zip.text(of: entry, limit: 5_000_000).map { HTMLText.plain($0) }
            }
            guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            parts.append("[\(entry.path)]\n\(text)")
            total += text.count
        }
        return parts.joined(separator: "\n\n")
    }

    /// Text inside Office XML: paragraph and row ends become new lines.
    private static func xmlText(_ xml: String) -> String {
        var text = xml
        for tag in ["</w:p>", "</a:p>", "</si>", "</row>", "<w:br/>", "<a:br/>"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }
        text = text.replacingOccurrences(of: "<w:tab/>", with: "\t")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTMLText.decodeEntities(text)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    /// Text in a photo or scan, read on the phone with Apple's Vision.
    static func imageText(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data)?.cgImage else { throw ExtractError.empty }
        return try await recognizeText(in: image)
    }

    static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

/// Readable text from JSON: every string value on its own line, with its key.
enum JSONText {
    static func flatten(_ raw: String, limit: Int = 2_000_000) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return raw }
        var lines: [String] = []
        var size = 0
        func walk(_ value: Any, key: String) {
            guard size < limit else { return }
            switch value {
            case let dictionary as [String: Any]:
                for (childKey, child) in dictionary.sorted(by: { $0.key < $1.key }) {
                    walk(child, key: childKey)
                }
            case let array as [Any]:
                for child in array { walk(child, key: key) }
            case let text as String:
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned.count < 5_000 else { return }
                let line = key.isEmpty ? cleaned : "\(key): \(cleaned)"
                lines.append(line)
                size += line.count
            case let number as NSNumber:
                // Timestamps and ids add noise; keep only short numbers with a
                // meaningful key.
                if !key.isEmpty, !key.lowercased().contains("time"), !key.lowercased().contains("id") {
                    lines.append("\(key): \(number)")
                }
            default:
                return
            }
        }
        walk(object, key: "")
        return lines.joined(separator: "\n")
    }
}
