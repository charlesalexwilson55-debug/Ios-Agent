import CryptoKit
import Foundation
import SwiftUI

enum PCOutbox {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PC Outbox", isDirectory: true)
    }
    static var receiverConnected: Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("receiver.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let time = json["time"] else { return false }
        return abs(Date().timeIntervalSince1970 - time) < 12
    }
    static func queue(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 100_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(id + ".payload"), options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let request: [String: Any] = ["name": url.lastPathComponent, "bytes": data.count, "sha256": hash]
        do {
            try JSONSerialization.data(withJSONObject: request).write(
                to: folder.appendingPathComponent(id + ".request.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".payload"))
            throw error
        }
        return id
    }
    static func acknowledged(_ id: String) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(id + ".ack.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["ok"] as? Bool == true
    }
}

struct SendToPCButton: View {
    let file: () throws -> URL
    @State private var pending: String?
    @State private var sent = false
    @State private var error: String?
    @State private var connected = false
    var body: some View {
        Button {
            do { pending = try PCOutbox.queue(file()); error = nil }
            catch { self.error = error.localizedDescription }
        } label: {
            Label(sent ? "Sent to PC" : pending != nil ? "Queued for PC" : "Send to PC",
                  systemImage: sent ? "checkmark.circle" : "desktopcomputer")
        }
        .disabled(pending != nil)
        .help(connected ? "USB receiver connected" : "Start the Conduit USB receiver on your PC; exports wait here until it connects.")
        .task {
            while !Task.isCancelled {
                connected = PCOutbox.receiverConnected
                if let pending { sent = PCOutbox.acknowledged(pending) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Could not queue export", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
