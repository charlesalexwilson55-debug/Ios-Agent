import Foundation

@main
struct Tests {
    static func main() {
        assert(ResponseTextCleaner.clean("<answer>42</answer>") == "42")
        assert(ResponseTextCleaner.clean("<question?=false>Paris<answer>France</answer>") == "ParisFrance")
        assert(ResponseTextCleaner.clean("<answer>\nHello\n</answer>") == "Hello")
        assert(ResponseTextCleaner.clean("The HTML is `<div>`.") == "The HTML is `<div>`.")
        assert(ResponseTextCleaner.clean("```html\n<answer>kept</answer>\n```") == "```html\n<answer>kept</answer>\n```")
        assert(ResponseTextCleaner.clean("Ready <answ", streaming: true) == "Ready")
        let rawFunction = "function solve(input) {\n    return input.reduce((a, b) => a + b, 0);\n}"
        assert(ResponseTextCleaner.clean(rawFunction) == "```javascript\n\(rawFunction)\n```",
               "Standalone JavaScript must render in the existing copyable code block")
        assert(ResponseTextCleaner.clean(rawFunction, streaming: true) == rawFunction,
               "Do not switch layout before the function finishes streaming")
        let literal = "async function show() { return '<answer>example</answer>'; }"
        assert(ResponseTextCleaner.clean(literal) == "```javascript\n\(literal)\n```",
               "Protocol-like strings inside code are literal content")
        assert(ResponseTextCleaner.clean("The function solve(input) adds numbers.") == "The function solve(input) adds numbers.")
        assert(ResponseTextCleaner.clean("```javascript\n\(rawFunction)\n```") == "```javascript\n\(rawFunction)\n```")
        assert(ResponseTextCleaner.displayProse("* First\n- Second\n## Title") == "• First\n• Second\n**Title**")
        assert(ResponseTextCleaner.displayProse("2 * 3 = 6 and **bold** with `x * y`") == "2 * 3 = 6 and **bold** with `x * y`")
        print("Response cleaner OK")
        assert(ResponseTextCleaner.displayProse("Read https://example.com/a?b=2.") == "Read [example.com](https://example.com/a?b=2).")
        assert(ResponseTextCleaner.displayProse("[Source](https://example.com/a) and `https://example.com/b`") == "[Source](https://example.com/a) and `https://example.com/b`")
        assert(ResponseTextCleaner.displayProse("First — second") == "First\n\nsecond")
        assert(ResponseTextCleaner.displayProse("`x — y`") == "`x — y`")
    }
}
