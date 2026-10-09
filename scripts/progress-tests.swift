import Foundation

@main struct ProgressTests {
    static func main() {
        typealias Row = TranscriptProgress.Row
        let oldResearch = Row(runningTitles: ["Loading old archive"])
        precondition(TranscriptProgress.label(rows: [oldResearch, Row(isUser: true)], thinking: true) == "Thinking",
                     "An unfinished historical task must not label a new turn Loading")
        let research = [Row(isUser: true), Row(runningTitles: ["Searching sources"])]
        precondition(TranscriptProgress.label(rows: research, thinking: false) == "Researching")
        precondition(TranscriptProgress.label(rows: research + [Row(isStreaming: true)], thinking: false) == "Researching",
                     "An empty assistant placeholder must not hide the active research stage")
        precondition(TranscriptProgress.label(rows: research + [Row(isStreaming: true, hasAnswer: true)], thinking: true) == "Typing")
        precondition(TranscriptProgress.label(rows: [Row(isUser: true), Row(isTool: true)], thinking: false) == "Routing")
        precondition(TranscriptProgress.label(rows: [Row(isUser: true)], thinking: false) == "Working")
        print("Current-turn progress regressions passed")
    }
}
