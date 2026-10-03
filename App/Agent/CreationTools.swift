import Foundation

@MainActor final class CreationTools: ToolProviding {
    let specs: [ToolDescriptor] = [
        ToolDescriptor(name: "create_3d_object", description: "Create a simple local 3D object with interactive preview and exportable OBJ mesh. Compose up to 32 boxes and spheres. This is procedural geometry, not detailed sculpting. Use dimensions in metres; Y is up.",
            params: [.required("title", .string, "Short object name"),
                     .required("parts", .string, "JSON array: [{\"kind\":\"box\",\"size\":[1,1,1],\"position\":[0,0,0]}]. kind is box or sphere; size is full width/height/depth; position is centre. Each size is 0–20; position is -50–50.")],
            friction: .silent, category: "creation"),
        ToolDescriptor(name: "create_image", description: "Generate an image locally using Apple Image Playground. Requires Apple Intelligence and its downloaded image model. Supports illustration, sketch and animation; no online service.",
            params: [.required("prompt", .string, "Description of the image"), .optional("style", .string, "animation, illustration or sketch")],
            friction: .silent, category: "creation")
    ]
    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        do {
            if name == "create_image" {
                guard let prompt = arguments.string("prompt"), !prompt.isEmpty else { return .badArgument(name, "prompt", "An image description") }
                let style = ImageGenerator.Style(rawValue: arguments.string("style") ?? "animation") ?? .animation
                let image = try await ImageGenerator.create(prompt, style: style)
                guard let saved = ImageStore.shared.addCreated(image, prompt: prompt, style: style.rawValue) else { return .failure(name, "The generated image could not be saved.") }
                return .success(name, "Created your image", detail: ["image_id": saved.id.uuidString])
            }
            guard name == "create_3d_object", let title = arguments.string("title"),
                  let json = arguments.string("parts"), json.utf8.count <= 16000, let data = json.data(using: .utf8) else { return .failure(name, "Supply title and a JSON parts array.") }
            let parts = try JSONDecoder().decode([MeshAsset.Part].self, from: data)
            let mesh = try MeshAsset.make(title: title, parts: parts)
            try FileManager.default.createDirectory(at: MeshAsset.folder, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let meshURL = MeshAsset.folder.appendingPathComponent(id + ".json")
            try JSONEncoder().encode(mesh).write(to: meshURL, options: .atomic)
            try mesh.obj.write(to: MeshAsset.folder.appendingPathComponent(id + ".obj"), atomically: true, encoding: .utf8)
            return .success(name, "Created \(title)", detail: ["object_id": id, "format": "OBJ", "note": "Simple procedural mesh. Preview and export are attached to this chat."])
        } catch { return .failure(name, error.localizedDescription) }
    }
}
