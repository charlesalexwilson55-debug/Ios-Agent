import Foundation

@main struct Edge0Tests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exact bit preservation at the first, middle and last expert offsets.
        let input = root.appendingPathComponent("source.bin"), output = root.appendingPathComponent("layer.bin")
        var stacked = Data()
        for expert in 0..<256 { stacked.append(Data(repeating: UInt8(expert), count: 32_768)) }
        try stacked.write(to: input)
        let tensor = Edge0Packing.Tensor(dtype: "BF16", shape: [256, 16_384], data_offsets: [0, Int64(stacked.count)])
        try Edge0Packing.scatter(input, to: output, part: 1, tensor: tensor)
        let file = try FileHandle(forReadingFrom: output)
        for expert in [0, 127, 255] {
            try file.seek(toOffset: UInt64(Int64(expert) * Edge0Packing.blockBytes + Edge0Packing.partOffset(1)))
            let readBack = try file.read(upToCount: 32_768)
            precondition(readBack == Data(repeating: UInt8(expert), count: 32_768))
        }
        try file.close()
        do {
            try Edge0Packing.scatter(input, to: output, part: 1,
                tensor: .init(dtype: "BF16", shape: [255, 16_384], data_offsets: [0, Int64(stacked.count)]))
            fatalError("Wrong expert count was accepted")
        } catch {}
        let fixture: [String: Any] = ["model": ["type": "BPE", "vocab": ["a": 0, "b": 1, "ab": 2], "merges": [["a", "b"]]],
            "added_tokens": [["id": 3, "content": "<eos>"]],
            "pre_tokenizer": ["pretokenizers": [["pattern": ["Regex": ".+"]]]]]
        let json = root.appendingPathComponent("tokenizer.json"), binary = root.appendingPathComponent("tokenizer.bin")
        try JSONSerialization.data(withJSONObject: fixture).write(to: json)
        try Edge0Packing.tokenizer(json, to: binary)
        let data = try Data(contentsOf: binary), length = try Edge0Packing.uint64(Data(data.prefix(8)))
        let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<8 + Int(length))) as! [String: Any]
        precondition(header["vocab_size"] as? Int == 4 && header["merge_count"] as? Int == 1)
        let expected = [UInt32(0), 1, 2, 4, 9].reduce(Data()) { $0 + Edge0Packing.little($1) }
            + Data("abab<eos>".utf8) + Edge0Packing.little(UInt32(0)) + Edge0Packing.little(UInt32(1))
            + Edge0Packing.little(UInt32(3)) + Edge0Packing.little(UInt32(0)) + Edge0Packing.little(UInt32(5)) + Data("<eos>".utf8)
        precondition(data.dropFirst(8 + Int(length)) == expected)

        var heads: [String: Edge0Packing.Tensor] = [:], bytes = Data(), cursor: Int64 = 0
        for owner in 6...38 {
            for part in ["fc1", "fc2", "linear_init"] {
                heads["layers.\(owner).\(part).weight"] = .init(dtype: "F16", shape: [2, 3], data_offsets: [cursor, cursor + 12])
                for i in 0..<6 { bytes.append(Edge0Packing.little(UInt16(owner * 10 + i))) }
                cursor += 12
            }
        }
        let encoded = try JSONEncoder().encode(heads)
        let headInput = root.appendingPathComponent("heads.safetensors"), headOutput = root.appendingPathComponent("stacked.safetensors")
        try (Edge0Packing.little(UInt64(encoded.count)) + encoded + bytes).write(to: headInput)
        try Edge0Packing.pregate(headInput, to: headOutput)
        let converted = try Data(contentsOf: headOutput)
        let headLength = try Edge0Packing.uint64(Data(converted.prefix(8)))
        let convertedHeader = try Edge0Packing.header(converted.subdata(in: 8..<8 + Int(headLength)))
        let start = 8 + Int(headLength) + Int(convertedHeader["pregate.fc1"]!.data_offsets[0])
        let transposed = [60, 63, 61, 64, 62, 65].reduce(Data()) { $0 + Edge0Packing.little(UInt16($1)) }
        precondition(converted.subdata(in: start..<start + 12) == transposed)
        precondition(convertedHeader["pregate.fc1"]!.shape == [33, 3, 2])

        var parser = Edge0Protocol.Parser(thinking: true)
        var prose = "", reasoning = "", calls: [(String, Data)] = []
        let stream = "secret</think>Answer<tool_call>{\"name\":\"web_search\",\"arguments\":{\"query\":\"test\"}}</tool_call>"
        for char in stream {
            for piece in try parser.feed(String(char)) {
                switch piece { case .text(let s): prose += s; case .reasoning(let s): reasoning += s; case .call(let n, let d): calls.append((n,d)) }
            }
        }
        _ = try parser.feed("", final: true)
        precondition(prose == "Answer" && reasoning == "secret" && calls.count == 1 && calls[0].0 == "web_search")
        var xml = Edge0Protocol.Parser(thinking: false)
        let pieces = try xml.feed("<tool_call><function=run_javascript><parameter=code>2 + 2</parameter></function></tool_call>", final: true)
        guard let first = pieces.first, case .call(let name, let arguments) = first else { fatalError("XML call missing") }
        let xmlArguments = try JSONSerialization.jsonObject(with: arguments) as? [String: String]
        precondition(name == "run_javascript" && xmlArguments?["code"] == "2 + 2")
        var broken = Edge0Protocol.Parser(thinking: false)
        do { _ = try broken.feed("<tool_call>{", final: true); fatalError("Incomplete tool call accepted") } catch {}
        let prompt = try Edge0Protocol.prompt(messages: [.init(role: "system", content: "Help"), .init(role: "user", content: "Question"), .init(role: "tool", content: "Result")], schemas: [], thinking: false, small: false)
        precondition(prompt.contains("<tool_response>\nResult") && prompt.hasSuffix("<think>\n\n</think>\n\n"))
        print("Edge0 tests passed: expert layout, invalid shape, tokenizer bytes, fp16 head transpose, split protocol tags, JSON/XML tool calls, incomplete calls, tool history.")
    }
}
