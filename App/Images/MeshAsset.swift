import Foundation

/// Small procedural meshes, not a trained text-to-3D model. All geometry is
/// bounded before allocation and export so malformed tool input stays small.
struct MeshAsset: Codable {
    struct Part: Codable {
        let kind: String
        let size: [Double]
        let position: [Double]
    }
    let title: String
    let vertices: [[Double]]
    let triangles: [[Int]]
    enum MeshError: LocalizedError {
        case invalid
        var errorDescription: String? { "Use 1–32 boxes or spheres, each with three finite size and position numbers. Sizes must be greater than zero and no larger than 20." }
    }

    static func make(title: String, parts: [Part]) throws -> Self {
        guard (1...32).contains(parts.count), (1...100).contains(title.count) else { throw MeshError.invalid }
        var vertices: [[Double]] = [], triangles: [[Int]] = []
        for part in parts {
            guard ["box", "sphere"].contains(part.kind), part.size.count == 3, part.position.count == 3,
                  part.size.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 20 }),
                  part.position.allSatisfy({ $0.isFinite && abs($0) <= 50 }) else { throw MeshError.invalid }
            let base = vertices.count
            func point(_ x: Double, _ y: Double, _ z: Double) {
                vertices.append([x * part.size[0] + part.position[0], y * part.size[1] + part.position[1], z * part.size[2] + part.position[2]])
            }
            if part.kind == "box" {
                for z in [-0.5, 0.5] { for y in [-0.5, 0.5] { for x in [-0.5, 0.5] { point(x, y, z) } } }
                for face in [[0,2,3,1], [4,5,7,6], [0,1,5,4], [2,6,7,3], [0,4,6,2], [1,3,7,5]] {
                    triangles.append([base+face[0], base+face[1], base+face[2]])
                    triangles.append([base+face[0], base+face[2], base+face[3]])
                }
            } else {
                let rows = 12, columns = 16
                for row in 0...rows {
                    let angle = Double(row) * Double.pi / Double(rows)
                    for column in 0...columns {
                        let around = Double(column) * 2 * Double.pi / Double(columns)
                        point(0.5 * sin(angle) * cos(around), 0.5 * cos(angle), 0.5 * sin(angle) * sin(around))
                    }
                }
                for row in 0..<rows { for column in 0..<columns {
                    let a = base + row * (columns+1) + column, b = a + columns+1
                    triangles.append([a,b,a+1]); triangles.append([a+1,b,b+1])
                } }
            }
        }
        return Self(title: title, vertices: vertices, triangles: triangles)
    }

    var obj: String {
        let points = vertices.map { "v " + $0.map { String($0) }.joined(separator: " ") }
        let faces = triangles.map { "f " + $0.map { String($0 + 1) }.joined(separator: " ") }
        return (["# Conduit procedural mesh"] + points + faces).joined(separator: "\n") + "\n"
    }
    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Objects", isDirectory: true) }
}
