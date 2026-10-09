import Foundation

@main struct CalculatorPromptTests {
    static func main() {
        let calculator = ToolDescriptor(name: "run_javascript", description: "Calculate and check code")
        for mode in [SystemPrompt.Mode.answer, .task] {
            let prompt = SystemPrompt.build(tools: [calculator], mode: mode)
            precondition(prompt.contains("even simple arithmetic"))
            precondition(prompt.contains("empty input"))
            precondition(prompt.contains("actual tool result"))
            precondition(!SystemPrompt.build(tools: [], mode: mode).contains("even simple arithmetic"))
        }
        print("Calculator policy covers simple arithmetic and code boundaries only when the sandbox is available")
    }
}
