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
        print("Response cleaner OK")
    }
}
