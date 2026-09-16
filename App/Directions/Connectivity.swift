import Foundation
import Network
import Observation

/// Whether the phone currently has a network path.
///
/// Used to decide how directions are resolved: with a signal, places are
/// looked up exactly; without one, Maps is handed the names and searches the
/// areas downloaded for offline use.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "conduit.connectivity"))
    }
}
