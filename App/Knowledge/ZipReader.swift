import Compression
import Foundation

/// Reads files out of a ZIP archive: Word, PowerPoint and Excel documents are
/// ZIPs, and so are the data exports Instagram, TikTok and others hand out.
///
/// Supports stored and deflated entries, and ZIP64 archives. Encrypted
/// entries are skipped.
struct ZipReader {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let encrypted: Bool
    }

    enum ZipError: LocalizedError {
        case notZip
        case unsupported(String)
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notZip: "The file is not a ZIP archive."
            case .unsupported(let what): "The archive uses \(what), which Conduit cannot read."
            case .corrupt: "The archive is damaged."
            }
        }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try Self.readDirectory(data)
    }

    /// The uncompressed bytes of one entry, or nil when it is larger than
    /// `limit` or cannot be read.
    func read(_ entry: Entry, limit: Int = 30_000_000) -> Data? {
        guard !entry.encrypted, entry.size <= limit else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4b50 else { return nil }
        let nameLength = Int(data.uint16(at: header + 26))
        let extraLength = Int(data.uint16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { return nil }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { outBuffer -> Int in
                compressed.withUnsafeBytes { inBuffer -> Int in
                    guard let dst = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let src = inBuffer.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(dst, entry.size, src, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? output : nil
        default:
            return nil
        }
    }

    func text(of entry: Entry, limit: Int = 30_000_000) -> String? {
        read(entry, limit: limit).flatMap { TextExtractor.decode($0) }
    }

    // MARK: - Directory

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notZip }
        // The end-of-directory record sits in the last 22 bytes plus any
        // comment, which is at most 65,535 bytes.
        let lowest = max(0, data.count - 22 - 65_535)
        var end: Int?
        var position = data.count - 22
        while position >= lowest {
            if data.uint32(at: position) == 0x0605_4b50 {
                end = position
                break
            }
            position -= 1
        }
        guard let end else { throw ZipError.notZip }

        var count = Int(data.uint16(at: end + 10))
        var directoryOffset = Int(data.uint32(at: end + 16))

        // ZIP64: the real values are in a separate record found through a
        // locator just before the end record.
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF, end >= 20,
           data.uint32(at: end - 20) == 0x0706_4b50 {
            let record = Int(data.uint64(at: end - 12))
            guard record + 56 <= data.count, data.uint32(at: record) == 0x0606_4b50 else {
                throw ZipError.corrupt
            }
            count = Int(data.uint64(at: record + 32))
            directoryOffset = Int(data.uint64(at: record + 48))
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(count, 100_000))
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, data.uint32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.corrupt
            }
            let flags = data.uint16(at: cursor + 8)
            let method = data.uint16(at: cursor + 10)
            var compressed = Int(data.uint32(at: cursor + 20))
            var size = Int(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            var offset = Int(data.uint32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength <= data.count else { throw ZipError.corrupt }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let path = String(decoding: nameData, as: UTF8.self)

            // ZIP64 sizes and offset live in extra field 0x0001, in this order,
            // for whichever of them overflowed.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.uint16(at: extra)
                let length = Int(data.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        size = Int(data.uint64(at: field)); field += 8
                    }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        compressed = Int(data.uint64(at: field)); field += 8
                    }
                    if offset == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        offset = Int(data.uint64(at: field))
                    }
                }
                extra += 4 + length
            }

            if !path.hasSuffix("/") {
                entries.append(Entry(path: path, method: method, compressedSize: compressed,
                                     size: size, localHeaderOffset: offset,
                                     encrypted: flags & 1 != 0))
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: littleEndian(at: offset, width: 2))
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: littleEndian(at: offset, width: 4))
    }

    func uint64(at offset: Int) -> UInt64 {
        littleEndian(at: offset, width: 8)
    }

    private func littleEndian(at offset: Int, width: Int) -> UInt64 {
        guard offset >= 0, offset + width <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<width {
            value |= UInt64(self[startIndex + offset + index]) << UInt64(8 * index)
        }
        return value
    }
}
