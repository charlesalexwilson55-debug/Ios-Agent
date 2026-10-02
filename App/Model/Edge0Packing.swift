import Foundation

/// Byte-preserving conversion of the published Edge0 checkpoint into its iOS layout.
/// No inference or floating-point conversion happens while preparing the model.
enum Edge0Packing {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Tensor: Codable {
        let dtype: String
        let shape: [Int]
        let data_offsets: [Int64]
        var count: Int64 { data_offsets[1] - data_offsets[0] }
    }
    static let blockBytes: Int64 = 1_769_472
    static let layerBytes = blockBytes * 256
    static let partNames = ["gate_proj.weight", "gate_proj.scales", "gate_proj.biases",
                            "up_proj.weight", "up_proj.scales", "up_proj.biases",
                            "down_proj.weight", "down_proj.scales", "down_proj.biases"]
    static let partBytes: [Int64] = [524_288, 32_768, 32_768, 524_288, 32_768, 32_768, 524_288, 32_768, 32_768]

    static func header(_ data: Data) throws -> [String: Tensor] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Invalid weights header.")
        }
        var result: [String: Tensor] = [:]
        for (key, value) in json where key != "__metadata__" {
            let encoded = try JSONSerialization.data(withJSONObject: value)
            let tensor = try JSONDecoder().decode(Tensor.self, from: encoded)
            guard tensor.data_offsets.count == 2, tensor.data_offsets[0] >= 0,
                  tensor.data_offsets[1] > tensor.data_offsets[0],
                  !tensor.shape.isEmpty, tensor.shape.allSatisfy({ $0 > 0 }) else {
                throw Failure(message: "Invalid tensor bounds: \(key).")
            }
            result[key] = tensor
        }
        return result
    }
    static func uint64(_ data: Data) throws -> UInt64 {
        guard data.count == 8 else { throw Failure(message: "Incomplete weights header.") }
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
    static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        var number = value.littleEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    static func expertPart(_ name: String) throws -> (layer: Int, part: Int)? {
        guard name.contains(".switch_mlp.") else { return nil }
        let pieces = name.components(separatedBy: ".layers.")
        guard pieces.count == 2, let layer = Int(pieces[1].components(separatedBy: ".")[0]),
              (0..<40).contains(layer),
              let tail = name.components(separatedBy: ".switch_mlp.").last,
              let part = partNames.firstIndex(of: tail) else {
            throw Failure(message: "Unsupported expert layout: \(name).")
        }
        return (layer, part)
    }
    static func partOffset(_ part: Int) -> Int64 { partBytes.prefix(part).reduce(0, +) }

    /// Scatter one stacked tensor into 256 contiguous expert blocks. Verify every write.
    static func scatter(_ source: URL, to output: URL, part: Int, tensor: Tensor) throws {
        guard tensor.shape.first == 256, tensor.count == partBytes[part] * 256 else {
            throw Failure(message: "This checkpoint's expert shape is not supported.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let destination = try FileHandle(forUpdating: output)
        defer { try? destination.close() }
        try destination.truncate(atOffset: UInt64(layerBytes))
        for expert in 0..<256 {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: Int(partBytes[part])) ?? Data()
            guard bytes.count == Int(partBytes[part]) else {
                throw Failure(message: "Incomplete expert download.")
            }
            let offset = UInt64(Int64(expert) * blockBytes + partOffset(part))
            try destination.seek(toOffset: offset)
            try destination.write(contentsOf: bytes)
            try destination.seek(toOffset: offset)
            guard try destination.read(upToCount: bytes.count) == bytes else {
                throw Failure(message: "Expert verification failed. Retry the download.")
            }
        }
        try destination.synchronize()
    }

    static func copy(_ source: URL, to output: URL, at offset: UInt64, count: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        let destination = try FileHandle(forUpdating: output)
        defer { try? input.close(); try? destination.close() }
        var remaining = count
        var position = offset
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try input.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
            guard !data.isEmpty else { throw Failure(message: "Incomplete resident weights.") }
            try destination.seek(toOffset: position)
            try destination.write(contentsOf: data)
            try destination.seek(toOffset: position)
            guard try destination.read(upToCount: data.count) == data else {
                throw Failure(message: "Resident weight verification failed.")
            }
            remaining -= Int64(data.count); position += UInt64(data.count)
        }
        try destination.synchronize()
    }

    /// Match tools/convert_tokenizer.py exactly, without installing Python on the phone.
    static func tokenizer(_ source: URL, to output: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        guard let model = json?["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [[String]],
              let pre = json?["pre_tokenizer"] as? [String: Any],
              let preItems = pre["pretokenizers"] as? [[String: Any]],
              let pattern = preItems.first?["pattern"] as? [String: Any],
              let regex = pattern["Regex"] as? String else {
            throw Failure(message: "Unsupported tokenizer format.")
        }
        let added = json?["added_tokens"] as? [[String: Any]] ?? []
        var byID: [Int: String] = [:]
        for (word, id) in vocab { byID[id] = word }
        for item in added {
            guard let id = item["id"] as? Int, let text = item["content"] as? String else {
                throw Failure(message: "Invalid tokenizer special token.")
            }
            byID[id] = text
        }
        let size = (byID.keys.max() ?? -1) + 1
        guard size > 0, size < 1_000_000 else { throw Failure(message: "Invalid vocabulary size.") }
        var blob = Data(), offsets = little(UInt32(0)), pairs = Data()
        for id in 0..<size {
            guard let text = byID[id] else { throw Failure(message: "Tokenizer vocabulary has missing entries.") }
            blob.append(contentsOf: text.utf8); offsets.append(little(UInt32(blob.count)))
        }
        for pair in merges {
            guard pair.count == 2, let a = vocab[pair[0]], let b = vocab[pair[1]] else {
                throw Failure(message: "Invalid tokenizer merge.")
            }
            pairs.append(little(UInt32(a))); pairs.append(little(UInt32(b)))
        }
        var specialIDs = Data(), specialOffsets = little(UInt32(0)), specialBlob = Data()
        for item in added {
            specialIDs.append(little(UInt32(item["id"] as! Int)))
            specialBlob.append(contentsOf: (item["content"] as! String).utf8)
            specialOffsets.append(little(UInt32(specialBlob.count)))
        }
        let header: [String: Any] = ["format": "edge0-tokenizer-v1", "vocab_size": size,
            "merge_count": merges.count, "special_count": added.count, "regex": regex,
            "normalizer": (json?["normalizer"] as? [String: Any])?["type"] ?? NSNull(),
            "byte_level": true, "sections": ["vocab_offsets", "vocab_blob", "merge_pairs",
                "special_ids", "special_offsets", "special_blob"]]
        let encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var result = little(UInt64(encoded.count)); result.append(encoded)
        for section in [offsets, blob, pairs, specialIDs, specialOffsets, specialBlob] { result.append(section) }
        try result.write(to: output, options: .atomic)
    }

    /// Stack and transpose fp16 routing heads without changing a single floating-point bit.
    static func pregate(_ source: URL, to output: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try uint64(input.read(upToCount: 8) ?? Data())
        guard length < 64 * 1_048_576 else { throw Failure(message: "Routing header is too large.") }
        let tensors = try header(input.read(upToCount: Int(length)) ?? Data())
        let owners = Set(tensors.keys.compactMap { Int($0.components(separatedBy: ".").dropFirst().first ?? "") }).sorted()
        guard owners == Array(6...38) else { throw Failure(message: "Unexpected routing head owners.") }
        var outputHeader: [String: Tensor] = [:], cursor: Int64 = 0
        for part in ["fc1", "fc2", "linear_init"] {
            guard let first = tensors["layers.\(owners[0]).\(part).weight"], first.dtype == "F16", first.shape.count == 2 else {
                throw Failure(message: "Missing routing head: \(part).")
            }
            let count = first.count * Int64(owners.count)
            outputHeader["pregate.\(part)"] = Tensor(dtype: "F16", shape: [owners.count, first.shape[1], first.shape[0]], data_offsets: [cursor, cursor + count])
            cursor += count
        }
        outputHeader["pregate.owners"] = Tensor(dtype: "I32", shape: [owners.count], data_offsets: [cursor, cursor + Int64(owners.count * 4)])
        var encoded = try JSONEncoder().encode(outputHeader)
        encoded.append(contentsOf: repeatElement(UInt8(32), count: (8 - encoded.count % 8) % 8))
        FileManager.default.createFile(atPath: output.path, contents: little(UInt64(encoded.count)) + encoded)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        try destination.seekToEnd()
        for part in ["fc1", "fc2", "linear_init"] {
            for owner in owners {
                try Task.checkCancellation()
                guard let tensor = tensors["layers.\(owner).\(part).weight"], tensor.dtype == "F16", tensor.shape.count == 2,
                      let first = tensors["layers.\(owners[0]).\(part).weight"], tensor.shape == first.shape,
                      tensor.count == Int64(tensor.shape[0] * tensor.shape[1] * 2) else {
                    throw Failure(message: "Invalid routing head shape.")
                }
                try input.seek(toOffset: 8 + length + UInt64(tensor.data_offsets[0]))
                let bytes = try input.read(upToCount: Int(tensor.count)) ?? Data()
                guard bytes.count == Int(tensor.count) else { throw Failure(message: "Incomplete routing heads.") }
                var transposed = Data(count: bytes.count)
                bytes.withUnsafeBytes { raw in
                    transposed.withUnsafeMutableBytes { target in
                        let a = raw.bindMemory(to: UInt16.self), b = target.bindMemory(to: UInt16.self)
                        for row in 0..<tensor.shape[0] {
                            for column in 0..<tensor.shape[1] { b[column * tensor.shape[0] + row] = a[row * tensor.shape[1] + column] }
                        }
                    }
                }
                try destination.write(contentsOf: transposed)
            }
        }
        for owner in owners { try destination.write(contentsOf: little(Int32(owner))) }
        try destination.synchronize()
    }
}
