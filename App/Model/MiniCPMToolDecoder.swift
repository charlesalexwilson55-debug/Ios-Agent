import Foundation

/// MiniCPM5 uses XML function/param calls, which the pinned MLX parser does not
/// recognize. Only complete, schema-valid calls outside code examples execute.
enum MiniCPMToolDecoder {
    struct Schema: Sendable {
        let name: String
        let types: [String: String]
        let required: Set<String>
    }
    struct Call: Sendable { let name: String; let arguments: Data }
    struct Output: Sendable { let text: String; let calls: [Call] }
    enum DecodingError: LocalizedError {
        case invalidCall
        var errorDescription: String? {
            "The model produced an incomplete or invalid tool command. No action was performed. Try again."
        }
    }

    static func parse(_ text: String, schemas: [Schema]) throws -> Output {
        guard text.utf8.count <= 100_000 else { throw DecodingError.invalidCall }
        var remainder = text[...]
        var visible = ""
        var calls: [Call] = []
        var inFence = false
        while !remainder.isEmpty {
            let fence = remainder.range(of: "```")
            let function = inFence ? nil : remainder.range(of: "<function")
            if let fence, function == nil || fence.lowerBound < function!.lowerBound {
                visible += String(remainder[..<fence.upperBound])
                remainder = remainder[fence.upperBound...]
                inFence.toggle()
            } else if let function {
                visible += String(remainder[..<function.lowerBound])
                var cursor = function.upperBound
                var closing: Range<String.Index>?
                while cursor < remainder.endIndex {
                    let end = remainder.range(of: "</function>", range: cursor..<remainder.endIndex)
                    let cdata = remainder.range(of: "<![CDATA[", range: cursor..<remainder.endIndex)
                    if let cdata, end == nil || cdata.lowerBound < end!.lowerBound {
                        guard let terminator = remainder.range(of: "]]>", range: cdata.upperBound..<remainder.endIndex) else {
                            throw DecodingError.invalidCall
                        }
                        cursor = terminator.upperBound
                    } else { closing = end; break }
                }
                guard let closing else { throw DecodingError.invalidCall }
                let block = String(remainder[function.lowerBound..<closing.upperBound])
                let delegate = FunctionXML()
                let parser = XMLParser(data: Data(block.utf8))
                parser.delegate = delegate
                parser.shouldResolveExternalEntities = false
                parser.externalEntityResolvingPolicy = .never
                guard parser.parse(), !delegate.invalid, delegate.depth == 0,
                      let name = delegate.name, let schema = schemas.first(where: { $0.name == name }),
                      schema.required.isSubset(of: Set(delegate.values.keys)),
                      Set(delegate.values.keys).isSubset(of: Set(schema.types.keys)) else {
                    throw DecodingError.invalidCall
                }
                var arguments: [String: Any] = [:]
                for (key, raw) in delegate.values {
                    if schema.types[key] == "string" { arguments[key] = raw; continue }
                    guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed),
                          valid(value, type: schema.types[key] ?? "") else { throw DecodingError.invalidCall }
                    arguments[key] = value
                }
                calls.append(Call(name: name, arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)))
                remainder = remainder[closing.upperBound...]
            } else { visible += String(remainder); break }
        }
        return Output(text: visible.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls)
    }

    private static func valid(_ value: Any, type: String) -> Bool {
        switch type {
        case "integer", "number":
            guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return false }
            return number.doubleValue.isFinite && (type == "number" || number.doubleValue.rounded() == number.doubleValue)
        case "boolean": return (value as? NSNumber).map { String(cString: $0.objCType) == "c" } ?? false
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    private final class FunctionXML: NSObject, XMLParserDelegate {
        var depth = 0
        var invalid = false
        var name: String?
        var values: [String: String] = [:]
        var key: String?
        var value = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1, elementName == "function", attributes.count == 1, let name = attributes["name"] {
                self.name = name
            } else if depth == 2, elementName == "param", attributes.count == 1, let key = attributes["name"], values[key] == nil {
                self.key = key; value = ""
            } else { invalid = true; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if key != nil { value += string }
            else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid = true }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard key != nil, let string = String(data: CDATABlock, encoding: .utf8) else { invalid = true; return }
            value += string
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 2, elementName == "param", let key { values[key] = value; self.key = nil }
            depth -= 1
        }
    }
}
