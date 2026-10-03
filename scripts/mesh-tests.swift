import Foundation
@main struct MeshTests {
    static func main() throws {
        let box = try MeshAsset.make(title: "Box", parts: [.init(kind: "box", size: [2,4,6], position: [3,0,0])])
        precondition(box.vertices.count == 8 && box.triangles.count == 12)
        precondition(box.vertices.map { $0[0] }.min() == 2 && box.vertices.map { $0[0] }.max() == 4)
        precondition(box.obj.contains("f 1 3 4"))
        let sphere = try MeshAsset.make(title: "Ball", parts: [.init(kind: "sphere", size: [1,1,1], position: [0,0,0])])
        precondition(sphere.vertices.count == 221 && sphere.triangles.count == 384)
        precondition(sphere.triangles.flatMap { $0 }.allSatisfy { sphere.vertices.indices.contains($0) })
        for part in [MeshAsset.Part(kind: "box", size: [0,1,1], position: [0,0,0]),
                     .init(kind: "box", size: [1,1,1], position: [.infinity,0,0]),
                     .init(kind: "script", size: [1,1,1], position: [0,0,0])] {
            do { _ = try MeshAsset.make(title: "Bad", parts: [part]); preconditionFailure("Invalid geometry accepted") }
            catch MeshAsset.MeshError.invalid { }
        }
        let encoded = try JSONEncoder().encode(box)
        let restored = try JSONDecoder().decode(MeshAsset.self, from: encoded)
        precondition(restored.obj == box.obj)
        print("Mesh bounds, export and persistence OK")
    }
}
