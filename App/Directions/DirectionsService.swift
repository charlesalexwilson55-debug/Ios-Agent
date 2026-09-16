import Foundation
import MapKit

/// Turns "from here to there" into Apple Maps directions.
///
/// One engine for both the Directions page and the chat tool, so they behave
/// the same. Each end of the trip is resolved in this order:
/// 1. a saved place ("home"), using its stored coordinate when it has one;
/// 2. an exact MapKit lookup, accepted only when it contains the street and
///    town the user gave (see `PlaceResolver`);
/// 3. with no signal, the text itself, which Maps searches in the areas the
///    user downloaded for offline use.
/// Maps does the routing and turn-by-turn guidance, online or offline.
@MainActor
enum DirectionsService {

    enum Outcome {
        /// Maps opened. `exact` is false when Maps was given names to search
        /// for itself, so Conduit cannot vouch that it picked the right place.
        case opened(from: String, to: String, exact: Bool)
        /// A place could not be pinned down; `options` are the closest matches.
        case unresolved(role: String, query: String, options: [String])
        case failed(String)
    }

    private enum Endpoint {
        case currentLocation
        case item(MKMapItem, label: String)
        case text(String)

        var label: String {
            switch self {
            case .currentLocation: "your current location"
            case .item(_, let label): label
            case .text(let text): text
            }
        }

        /// The value for a maps:// URL: coordinates when known, else the text.
        var urlValue: String? {
            switch self {
            case .currentLocation:
                return nil
            case .item(let item, _):
                let coordinate = item.placemark.coordinate
                return "\(coordinate.latitude),\(coordinate.longitude)"
            case .text(let text):
                return text
            }
        }
    }

    private enum Lookup {
        case found(Endpoint)
        case unresolved([String])
    }

    static func open(from origin: String?, to destination: String, mode: TravelMode) async -> Outcome {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return .failed("No destination was given.") }
        let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let start: Endpoint
        if origin.isEmpty || isCurrentLocation(origin) {
            start = .currentLocation
        } else {
            switch await lookUp(origin) {
            case .found(let endpoint): start = endpoint
            case .unresolved(let options):
                return .unresolved(role: "starting point", query: origin, options: options)
            }
        }

        let end: Endpoint
        switch await lookUp(destination) {
        case .found(let endpoint): end = endpoint
        case .unresolved(let options):
            return .unresolved(role: "destination", query: destination, options: options)
        }

        let exact: Bool
        let opened: Bool
        switch (start, end) {
        case (.text(_), _), (_, .text(_)):
            exact = false
            opened = await openByURL(start, end, mode: mode)
        default:
            exact = true
            opened = openWithItems(start, end, mode: mode)
        }
        guard opened else { return .failed("Could not open Maps.") }

        PlacesStore.shared.recordTrip(
            from: origin.isEmpty || isCurrentLocation(origin) ? nil : origin,
            to: destination,
            mode: mode
        )
        return .opened(from: start.label, to: end.label, exact: exact)
    }

    static func isCurrentLocation(_ text: String) -> Bool {
        ["current location", "my current location", "my location", "here", "where i am"]
            .contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Resolving

    private static func lookUp(_ query: String) async -> Lookup {
        var searchText = query
        if let place = PlacesStore.shared.place(named: query) {
            if let item = place.mapItem {
                return .found(.item(item, label: place.name))
            }
            searchText = place.address
        }

        switch await PlaceResolver.resolve(searchText) {
        case .found(let item, let description):
            return .found(.item(item, label: description))
        case .ambiguous(let options):
            return .unresolved(options)
        case .searchFailed:
            // Almost always no signal. Maps can still search its offline areas.
            return .found(.text(searchText))
        case .notFound:
            return Connectivity.shared.isOnline ? .unresolved([]) : .found(.text(searchText))
        }
    }

    // MARK: - Opening Maps

    private static func openWithItems(_ start: Endpoint, _ end: Endpoint, mode: TravelMode) -> Bool {
        guard case .item(let to, _) = end else { return false }
        let from: MKMapItem
        switch start {
        case .item(let item, _): from = item
        default: from = MKMapItem.forCurrentLocation()
        }
        return MKMapItem.openMaps(
            with: [from, to],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launchOption]
        )
    }

    private static func openByURL(_ start: Endpoint, _ end: Endpoint, mode: TravelMode) async -> Bool {
        var items: [URLQueryItem] = []
        if let from = start.urlValue {
            items.append(URLQueryItem(name: "saddr", value: from))
        }
        items.append(URLQueryItem(name: "daddr", value: end.urlValue ?? ""))
        items.append(URLQueryItem(name: "dirflg", value: mode.urlFlag))
        guard var components = URLComponents(string: "maps://") else { return false }
        components.queryItems = items
        guard let url = components.url else { return false }
        return await ComposePresenter.open(url)
    }
}
