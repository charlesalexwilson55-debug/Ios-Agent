import Foundation

@main struct MiniCPMToolTests {
    static func main() throws {
        let schema = MiniCPMToolDecoder.Schema(name: "run_javascript", types: ["code": "string"], required: ["code"])
        let raw = #"I will calculate it. <function name="run_javascript"><param name="code"><![CDATA[3 < 4 ? 391 : 0]]></param></function>"#
        let parsed = try MiniCPMToolDecoder.parse(raw, schemas: [schema])
        precondition(parsed.text == "I will calculate it.")
        precondition(parsed.calls.count == 1 && parsed.calls[0].name == "run_javascript")
        let arguments = try JSONSerialization.jsonObject(with: parsed.calls[0].arguments) as! [String: String]
        precondition(arguments["code"] == "3 < 4 ? 391 : 0")
        let example = "```xml\n" + raw + "\n```"
        let fenced = try MiniCPMToolDecoder.parse(example, schemas: [schema])
        precondition(fenced.calls.isEmpty)
        let two = raw + "\n" + raw
        let multiple = try MiniCPMToolDecoder.parse(two, schemas: [schema])
        precondition(multiple.calls.count == 2)
        let encoded = #"<function name="run_javascript"><param name="code">a &lt; b &amp;&amp; true</param></function>"#
        let decoded = try MiniCPMToolDecoder.parse(encoded, schemas: [schema])
        let strings = try JSONSerialization.jsonObject(with: decoded.calls[0].arguments) as! [String: String]
        precondition(strings["code"] == "a < b && true")
        for invalid in [
            #"<function name="unknown"><param name="code">1</param></function>"#,
            #"<function name="run_javascript"></function>"#,
            #"<function name="run_javascript"><param name="other">1</param></function>"#,
            #"<function name="run_javascript"><param name="code">1</param><param name="code">2</param></function>"#,
            #"<function name="run_javascript"><param name="code">1</param>"#,
            #"<function name="run_javascript"><param name="code"><evil>1</evil></param></function>"#
        ] {
            do { _ = try MiniCPMToolDecoder.parse(invalid, schemas: [schema]); preconditionFailure("Accepted invalid tool XML") }
            catch MiniCPMToolDecoder.DecodingError.invalidCall { }
        }
        let number = MiniCPMToolDecoder.Schema(name: "count", types: ["n": "integer"], required: ["n"])
        let numeric = try MiniCPMToolDecoder.parse(#"<function name="count"><param name="n">3</param></function>"#, schemas: [number])
        let numericArguments = try JSONSerialization.jsonObject(with: numeric.calls[0].arguments) as! [String: Int]
        precondition(numericArguments["n"] == 3)
        print("MiniCPM tools: real device XML, CDATA, entities, multiple calls, fenced examples and invalid calls OK")
    }
}
