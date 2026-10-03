import SwiftUI
import SceneKit

struct ObjectPreview: View {
    let id: String
    private var mesh: MeshAsset? {
        guard UUID(uuidString: id) != nil,
              let data = try? Data(contentsOf: MeshAsset.folder.appendingPathComponent(id + ".json")) else { return nil }
        return try? JSONDecoder().decode(MeshAsset.self, from: data)
    }
    var body: some View {
        if let mesh {
            VStack(spacing: 10) {
                SceneView(scene: scene(mesh), options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .frame(height: 250).clipShape(.rect(cornerRadius: 16))
                HStack {
                    Text(mesh.title).font(.headline)
                    Spacer()
                    ShareLink(item: MeshAsset.folder.appendingPathComponent(id + ".obj")) {
                        Label("Export OBJ", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered)
                }
            }.padding(12).background(.black.opacity(0.6), in: .rect(cornerRadius: 20))
        } else { Text("This 3D object is no longer available.").font(.caption) }
    }
    private func scene(_ mesh: MeshAsset) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        let points = mesh.vertices.map { SCNVector3(Float($0[0]), Float($0[1]), Float($0[2])) }
        let indices = mesh.triangles.flatMap { $0.map(Int32.init) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        geometry.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        let minX = mesh.vertices.map { $0[0] }.min() ?? -1, maxX = mesh.vertices.map { $0[0] }.max() ?? 1
        let minY = mesh.vertices.map { $0[1] }.min() ?? -1, maxY = mesh.vertices.map { $0[1] }.max() ?? 1
        let minZ = mesh.vertices.map { $0[2] }.min() ?? -1, maxZ = mesh.vertices.map { $0[2] }.max() ?? 1
        let span = max(max(maxX-minX, maxY-minY), max(maxZ-minZ, 1))
        camera.position = SCNVector3(Float((minX+maxX)/2 + span), Float((minY+maxY)/2 + span), Float(maxZ + span*2))
        camera.look(at: SCNVector3(Float((minX+maxX)/2), Float((minY+maxY)/2), Float((minZ+maxZ)/2)))
        scene.rootNode.addChildNode(camera)
        return scene
    }
}
