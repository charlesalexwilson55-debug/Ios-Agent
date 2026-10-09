import Foundation

struct VirtualFile: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let content: String
}

struct FileProject: Codable, Identifiable {
    let id: String
    let title: String
    let files: [VirtualFile]
    var folder: URL { Self.root.appendingPathComponent(id, isDirectory: true) }
    var entryPoint: URL? {
        let path = files.first { $0.path == "index.html" }?.path ?? files.first { $0.path.hasSuffix(".html") }?.path
        return path.map { folder.appendingPathComponent($0) }
    }
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }
    enum Invalid: LocalizedError {
        case files, path(String)
        var errorDescription: String? {
            switch self {
            case .files: "Supply 1–32 unique text files, up to 2 MB in total."
            case .path(let path): "Invalid project filename: \(path)"
            }
        }
    }
    static func validate(_ files: [VirtualFile]) throws {
        guard !files.isEmpty, files.count <= 32,
              Set(files.map { $0.path.lowercased() }).count == files.count,
              files.reduce(0, { $0 + $1.content.utf8.count }) <= 2_000_000 else { throw Invalid.files }
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, file.path.utf8.count < 240,
                  !file.path.contains("\\"), !file.path.contains(":"),
                  !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.path.hasPrefix("/"), file.path.lowercased() != "project.json", file.path.lowercased() != "project.zip",
                  !parts.contains(where: { part in
                      let stem = part.split(separator: ".").first?.uppercased() ?? ""
                      return ["CON", "PRN", "AUX", "NUL"].contains(stem)
                          || (1...9).contains(where: { stem == "COM\($0)" || stem == "LPT\($0)" })
                          || part.hasSuffix(".") || part.hasSuffix(" ")
                  }) else { throw Invalid.path(file.path) }
        }
        // A path cannot be both a file and another file's parent directory.
        for file in files where files.contains(where: { $0.path.lowercased().hasPrefix(file.path.lowercased() + "/") }) {
            throw Invalid.path(file.path)
        }
    }
    static func save(title: String, files: [VirtualFile], root: URL = Self.root) throws -> FileProject {
        try validate(files)
        let project = FileProject(id: UUID().uuidString, title: String(title.prefix(100)), files: files)
        let folder = root.appendingPathComponent(project.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                let url = folder.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.content.utf8).write(to: url, options: .atomic)
            }
            try JSONEncoder().encode(project).write(to: folder.appendingPathComponent("project.json"), options: .atomic)
            return project
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    static func load(_ id: String) -> FileProject? {
        guard UUID(uuidString: id) != nil,
              let data = try? Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent("project.json")),
              let project = try? JSONDecoder().decode(FileProject.self, from: data), project.id == id,
              (try? validate(project.files)) != nil else { return nil }
        return project
    }
    func export() throws -> URL {
        let url = folder.appendingPathComponent("project.zip")
        if !FileManager.default.fileExists(atPath: url.path) { try Self.archive(self).write(to: url, options: .atomic) }
        return url
    }
    /// Stored ZIP entries need no third-party compressor and preserve UTF-8 paths.
    static func archive(_ project: FileProject) throws -> Data {
        try validate(project.files)
        var data = Data(), central = Data()
        func append(_ value: UInt32, bytes: Int, to buffer: inout Data) {
            for byte in 0..<bytes { buffer.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
        }
        for file in project.files {
            let name = Data(file.path.utf8), body = Data(file.content.utf8)
            let offset = UInt32(data.count), size = UInt32(body.count), crc = crc32(body)
            append(0x04034b50, bytes: 4, to: &data)
            for field in [UInt32(20), 0x800, 0, 0, 33] { append(field, bytes: 2, to: &data) }
            for field in [crc, size, size] { append(field, bytes: 4, to: &data) }
            append(UInt32(name.count), bytes: 2, to: &data); append(0, bytes: 2, to: &data)
            data.append(name); data.append(body)
            append(0x02014b50, bytes: 4, to: &central)
            for field in [UInt32(20), 20, 0x800, 0, 0, 33] { append(field, bytes: 2, to: &central) }
            for field in [crc, size, size] { append(field, bytes: 4, to: &central) }
            for field in [UInt32(name.count), 0, 0, 0, 0] { append(field, bytes: 2, to: &central) }
            append(0, bytes: 4, to: &central); append(offset, bytes: 4, to: &central); central.append(name)
        }
        let offset = UInt32(data.count)
        data.append(central); append(0x06054b50, bytes: 4, to: &data)
        for field in [UInt32(0), 0, UInt32(project.files.count), UInt32(project.files.count)] { append(field, bytes: 2, to: &data) }
        append(UInt32(central.count), bytes: 4, to: &data); append(offset, bytes: 4, to: &data); append(0, bytes: 2, to: &data)
        return data
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
}

enum ArtifactParser {
    static func files(from text: String, complete: Bool) -> [VirtualFile] {
        guard complete else { return [] }
        var files: [VirtualFile] = [], header: String?, lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let value = header {
                    let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
                    let language = parts.first ?? ""
                    let explicit = parts.first { $0.hasPrefix("filename=") }?.dropFirst(9)
                    let ext = ["html": "html", "css": "css", "javascript": "js", "js": "js", "typescript": "ts", "python": "py", "swift": "swift", "json": "json"]
                    let path: String?
                    if let explicit { path = String(explicit).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    else if language.contains(".") { path = language }
                    else if let suffix = ext[language.lowercased()] {
                        path = suffix == "html" && !files.contains(where: { $0.path == "index.html" }) ? "index.html" : "file-\(files.count + 1).\(suffix)"
                    } else { path = nil }
                    guard let path else { return [] }
                    files.append(VirtualFile(path: path, content: lines.joined(separator: "\n")))
                    header = nil; lines = []
                } else { header = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)); lines = [] }
            } else if header != nil { lines.append(line) }
        }
        guard (try? FileProject.validate(files)) != nil else { return [] }
        return files
    }
}
