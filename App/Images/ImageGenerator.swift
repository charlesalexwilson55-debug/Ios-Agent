import CoreGraphics
import Foundation
import ImagePlayground

/// Makes images with Apple's on-device Image Playground model.
///
/// It is already on the phone with Apple Intelligence, needs no download,
/// and runs in its own system process, so it does not compete with the chat
/// model for Conduit's memory. It draws in animation, illustration and sketch
/// styles; it does not make photographs.
enum ImageGenerator {

    enum Style: String, CaseIterable, Identifiable {
        case animation, illustration, sketch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .animation: "Animation"
            case .illustration: "Illustration"
            case .sketch: "Sketch"
            }
        }

        var playground: ImagePlaygroundStyle {
            switch self {
            case .animation: return .animation
            case .illustration: return .illustration
            case .sketch: return .sketch
            }
        }
    }

    enum GenerationError: LocalizedError {
        case noImage
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .noImage: "The image model returned nothing. Try describing the picture differently."
            case .unavailable(let why): why
            }
        }
    }

    /// One image for the description.
    static func create(_ prompt: String, style: Style) async throws -> CGImage {
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            throw GenerationError.unavailable(
                "Apple's image model is not available: \(error.localizedDescription) It needs Apple "
                    + "Intelligence turned on in Settings, and the Image Playground model downloaded.")
        }
        let chosen = creator.availableStyles.contains(style.playground)
            ? style.playground
            : (creator.availableStyles.first ?? style.playground)
        let concept = String(prompt.prefix(400))
        for try await image in creator.images(for: [.text(concept)], style: chosen, limit: 1) {
            return image.cgImage
        }
        throw GenerationError.noImage
    }

    /// A style named in the request, or animation.
    static func style(for request: String) -> Style {
        let lower = request.lowercased()
        if ["sketch", "pencil", "line drawing", "doodle"].contains(where: { lower.contains($0) }) { return .sketch }
        if ["illustration", "illustrated", "painting", "painted", "watercolour", "watercolor", "flat"]
            .contains(where: { lower.contains($0) }) { return .illustration }
        return .animation
    }
}

/// Spots a request to make a picture, so it goes straight to the image
/// model instead of through the chat model.
enum ImageIntent {
    private static let fillers: Set<String> = [
        "please", "pls", "can", "could", "would", "will", "you", "hey", "hi", "conduit", "just",
        "i", "want", "need", "to", "me", "for", "quickly", "now",
    ]
    private static let drawVerbs: Set<String> = ["draw", "sketch", "paint", "illustrate", "doodle"]
    private static let makeVerbs: Set<String> = ["generate", "create", "make", "design", "render", "imagine", "produce"]
    private static let pictureNouns: Set<String> = [
        "image", "images", "picture", "pictures", "pic", "pics", "photo", "photos", "drawing", "illustration",
        "sketch", "painting", "artwork", "art", "wallpaper", "logo", "icon", "avatar", "poster", "cartoon",
        "sticker", "emoji", "portrait", "scene", "background",
    ]
    /// Nouns that are the subject themselves, so they stay in the prompt.
    private static let keptNouns: Set<String> = ["wallpaper", "logo", "icon", "avatar", "poster", "sticker", "emoji",
                                                 "portrait", "cartoon", "background"]
    private static let joiners: Set<String> = ["of", "showing", "with", "that", "where", "about", "depicting"]

    /// The description to draw, or nil when the request is not for a picture.
    static func prompt(from request: String) -> String? {
        let tokens = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        func word(_ token: String) -> String {
            token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        var index = 0
        while index < tokens.count, fillers.contains(word(tokens[index])) { index += 1 }
        guard index < tokens.count else { return nil }
        let verb = word(tokens[index])
        var rest = Array(tokens[(index + 1)...])

        if drawVerbs.contains(verb) {
            // "draw me a cat", "sketch a picture of a cat"
            while let first = rest.first, ["me", "us"].contains(word(first)) { rest.removeFirst() }
            return cleaned(stripNoun(rest))
        }
        guard makeVerbs.contains(verb) else { return nil }
        while let first = rest.first, ["me", "us"].contains(word(first)) { rest.removeFirst() }
        // A picture noun must come within the first few words.
        guard let nounIndex = rest.prefix(5).firstIndex(where: { pictureNouns.contains(word($0)) }) else {
            return nil
        }
        let noun = word(rest[nounIndex])
        if keptNouns.contains(noun) {
            return cleaned(Array(rest[nounIndex...]))
        }
        return cleaned(Array(rest[(nounIndex + 1)...]).droppingJoiner())
    }

    private static func stripNoun(_ words: [String]) -> [String] {
        let lowered = words.map { $0.lowercased() }
        // "a picture of a cat" → "a cat"
        if let nounIndex = lowered.prefix(4).firstIndex(where: { pictureNouns.contains($0) && !keptNouns.contains($0) }),
           nounIndex + 1 < words.count, joiners.contains(lowered[nounIndex + 1]) {
            return Array(words[(nounIndex + 2)...])
        }
        return words
    }

    private static func cleaned(_ words: [String]) -> String? {
        let text = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return text.count >= 2 ? text : nil
    }

    fileprivate static func isJoiner(_ word: String) -> Bool {
        joiners.contains(word.lowercased())
    }
}

private extension Array where Element == String {
    func droppingJoiner() -> [String] {
        guard let head = self.first, ImageIntent.isJoiner(head) else { return self }
        return Array(dropFirst())
    }
}
