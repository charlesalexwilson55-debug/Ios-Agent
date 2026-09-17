import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit
import Vision

/// Runs the image-reading model (Qwen3-VL) to describe pictures.
///
/// The phone cannot hold it and the chat model at once, so the chat model is
/// put aside while this one reads, and brought back afterwards.
actor VisionRunner {
    static let shared = VisionRunner()

    enum VisionError: LocalizedError {
        case badImage
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .badImage: "The picture could not be opened."
            case .notLoaded: "The image model is not loaded."
            }
        }
    }

    private var container: ModelContainer?
    private var loadedPath: String?

    static let describePrompt = """
    Describe this picture for someone who cannot see it.
    1. Start with one sentence saying what the picture is.
    2. Then list each notable thing and where it is in the frame (top left, top centre, top right, \
    middle left, centre, middle right, bottom left, bottom centre, bottom right, foreground or \
    background): people and what they are doing, objects, animals, places, colours and sizes.
    3. Quote any readable text exactly, and say where it is.
    4. End with what seems to be happening.
    Only describe what is visible. Do not guess names of people.
    """

    func load(directory: URL) async throws {
        guard loadedPath != directory.path else { return }
        container = nil
        MLX.Memory.clearCache()
        container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: #huggingFaceTokenizerLoader())
        loadedPath = directory.path
    }

    func describe(_ imageData: Data, question: String?) async throws -> String {
        guard let container else { throw VisionError.notLoaded }
        guard let image = CIImage(data: imageData) else { throw VisionError.badImage }
        var prompt = Self.describePrompt
        if let question, !question.isEmpty {
            prompt += "\nThe user said this about the picture: \u{201C}\(question)\u{201D}. Include whatever "
                + "they would need to get an answer."
        }
        let input = UserInput(chat: [.user(prompt, images: [.ciImage(image)])])
        let prepared = try await container.prepare(input: input)
        let parameters = GenerateParameters(maxTokens: 700, temperature: 0.2, topP: 0.9)
        var text = ""
        let stream = try await container.generate(input: prepared, parameters: parameters)
        for await event in stream {
            if Task.isCancelled { break }
            if case .chunk(let chunk) = event { text += chunk }
        }
        MLX.Memory.clearCache()
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        container = nil
        loadedPath = nil
        MLX.Memory.clearCache()
    }
}

/// A description made with Apple's Vision framework: the text in the picture
/// and where it is, what kind of scene it is, and how many faces. Used when
/// no image model is on the phone.
enum QuickVision {
    static func describe(_ data: Data) async throws -> String {
        guard let cgImage = UIImage(data: data)?.cgImage else { throw VisionRunner.VisionError.badImage }
        return try await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            let scene = VNClassifyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([text, scene, faces])

            var lines: [String] = []
            let labels = (scene.results ?? [])
                .filter { $0.confidence > 0.3 }
                .prefix(6)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            if !labels.isEmpty { lines.append("The picture looks like: " + labels.joined(separator: ", ") + ".") }
            let faceCount = faces.results?.count ?? 0
            if faceCount > 0 {
                lines.append(faceCount == 1 ? "There is 1 face, \(position(faces.results![0].boundingBox))."
                    : "There are \(faceCount) faces.")
            }
            let words = (text.results ?? []).compactMap { observation -> String? in
                guard let string = observation.topCandidates(1).first?.string else { return nil }
                return "\u{201C}\(string)\u{201D} (\(position(observation.boundingBox)))"
            }
            if !words.isEmpty {
                lines.append("Text in the picture: " + words.prefix(40).joined(separator: "; ") + ".")
            }
            return lines.isEmpty ? "Nothing recognisable was found in the picture." : lines.joined(separator: "\n")
        }.value
    }

    /// Where a Vision bounding box sits, in words. Vision's origin is the
    /// bottom left.
    static func position(_ box: CGRect) -> String {
        let x = box.midX
        let y = 1 - box.midY
        let row = y < 0.33 ? "top" : (y < 0.66 ? "middle" : "bottom")
        let column = x < 0.33 ? "left" : (x < 0.66 ? "centre" : "right")
        if row == "middle" && column == "centre" { return "centre" }
        return "\(row) \(column)"
    }
}
