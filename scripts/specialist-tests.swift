import Foundation

@main struct SpecialistTests {
    static func main() {
        precondition(ModelTaskRouter.role(for: "rewrite this sentence: The sky is blue", research: false) == .quickText)
        precondition(ModelTaskRouter.role(for: "translate this into French: Good morning", research: false) == .quickText)
        precondition(ModelTaskRouter.role(for: "send a message to my friend", research: false) == .chat)
        precondition(ModelTaskRouter.role(for: "read my photos and summarize them", research: false) == .chat)
        precondition(ModelTaskRouter.role(for: "rewrite this from https://example.com", research: false) == .chat)
        precondition(ModelTaskRouter.role(for: "debug this Swift code", research: false) == .heavy)
        precondition(ModelTaskRouter.role(for: "hello", research: true) == .researchCheck)
        precondition(ModelTaskRouter.role(for: "what is a computer?", research: false) == .chat)
        print("Specialist routing preserves actions, photos, web access and heavy code work")
    }
}
