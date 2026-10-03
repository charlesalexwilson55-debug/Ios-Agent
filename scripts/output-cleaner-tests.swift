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
        assert(ResponseTextCleaner.displayProse("* First\n- Second\n## Title") == "• First\n• Second\n**Title**")
        assert(ResponseTextCleaner.displayProse("2 * 3 = 6 and **bold** with `x * y`") == "2 * 3 = 6 and **bold** with `x * y`")
        print("Response cleaner OK")
        assert(ResponseTextCleaner.displayProse("Read https://example.com/a?b=2.") == "Read [example.com](https://example.com/a?b=2).")
        assert(ResponseTextCleaner.displayProse("[Source](https://example.com/a) and `https://example.com/b`") == "[Source](https://example.com/a) and `https://example.com/b`")
        assert(ResponseTextCleaner.displayProse("First — second") == "First\n\nsecond")
        assert(ResponseTextCleaner.displayProse("`x — y`") == "`x — y`")
    }
}
