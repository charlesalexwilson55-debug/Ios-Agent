import Foundation
import os

/// A plain-text log, plus a marker for work that never finished.
///
/// When iOS terminates an app for memory it often writes no crash report, and
/// the user only sees the app vanish. So before loading a model or generating
/// an answer a marker is written, and it is removed when that work ends. If
/// the marker is still there at the next launch, the previous run died in the
/// middle of that work, and the numbers in it show how close to the memory
/// limit it was.
///
/// The log lives in Documents, so it shows up in the Files app under
/// On My iPhone > Conduit and can be shared or pulled over USB.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "conduit.diagnostics")
    private static let maxLogBytes = 512 * 1024

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conduit-log.txt")
    }

    private static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unfinished-work.txt")
    }

    /// Appends one line. Synchronous, so the line is on disk before whatever
    /// comes next has a chance to take the process down.
    static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.sync { append(line) }
    }

    /// Records that `phase` has started. Pair with `end`.
    static func begin(_ phase: String, _ details: String) {
        queue.sync {
            let url = markerURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("\(phase) \(details)".utf8).write(to: url)
        }
        log("\(phase).start \(details)")
    }

    static func end(_ phase: String, _ details: String) {
        queue.sync { _ = try? FileManager.default.removeItem(at: markerURL) }
        log("\(phase).end \(details)")
    }

    /// What the previous run was doing when it died, if it died mid-work.
    /// Consumed on read.
    static func takeUnfinishedWork() -> String? {
        queue.sync { () -> String? in
            guard let data = try? Data(contentsOf: markerURL) else { return nil }
            try? FileManager.default.removeItem(at: markerURL)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Memory left before iOS terminates the app, in megabytes.
    static var availableMB: Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }

    private static func append(_ line: String) {
        let url = logURL
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > maxLogBytes {
            let old = url.deletingPathExtension().appendingPathExtension("old.txt")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
