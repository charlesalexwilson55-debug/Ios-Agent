import CoreLocation
import Foundation
import MapKit
import Observation

/// How to travel. Shared by the Directions page and the chat tool.
enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case driving, walking, transit, cycling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .driving: "Drive"
        case .walking: "Walk"
        case .transit: "Transit"
        case .cycling: "Cycle"
        }
    }

    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .cycling: "bicycle"
        }
    }

    var launchOption: String {
        switch self {
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .transit: MKLaunchOptionsDirectionsModeTransit
        case .cycling: MKLaunchOptionsDirectionsModeCycling
        }
    }

    /// The `dirflg` value in a maps:// URL.
    var urlFlag: String {
        switch self {
        case .driving: "d"
        case .walking: "w"
        case .transit: "r"
        case .cycling: "c"
        }
    }
}

/// A place the user named, such as Home.
///
/// The coordinate is captured when the place is saved with a signal. With it,
/// directions to the place work with no signal at all, because Maps is handed
/// an exact location instead of text it would have to search for.
struct SavedPlace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var resolvedAddress: String?
    var latitude: Double?
    var longitude: Double?

    var isPinned: Bool { latitude != nil && longitude != nil }

    /// A map item at the saved coordinate, or nil if the place was never pinned.
    var mapItem: MKMapItem? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

struct RecentTrip: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Nil means the user's current location.
    var from: String?
    var to: String
    var mode: TravelMode
    var date: Date
}

/// Saved places and recent trips, kept on the phone only.
@MainActor
@Observable
final class PlacesStore {
    static let shared = PlacesStore()

    private(set) var places: [SavedPlace] = []
    private(set) var recents: [RecentTrip] = []

    private static let placesKey = "conduit.directions.places"
    private static let recentsKey = "conduit.directions.recents"
    private static let recentLimit = 10
    private let defaults = UserDefaults.standard

    private init() {
        places = Self.load([SavedPlace].self, key: Self.placesKey) ?? []
        recents = Self.load([RecentTrip].self, key: Self.recentsKey) ?? []
    }

    // MARK: - Places

    /// The saved place a piece of text refers to: "home", "my home" and
    /// "Home" all find a place named Home.
    func place(named text: String) -> SavedPlace? {
        let key = Self.normalized(text)
        guard !key.isEmpty else { return nil }
        return places.first { Self.normalized($0.name) == key }
    }

    /// Adds or replaces a place, pinning its location first when possible.
    /// Returns the stored place so the caller can tell whether it was pinned.
    @discardableResult
    func save(_ place: SavedPlace) async -> SavedPlace {
        let pinned = await pin(place)
        if let index = places.firstIndex(where: { $0.id == pinned.id }) {
            places[index] = pinned
        } else {
            places.append(pinned)
        }
        persist()
        return pinned
    }

    func delete(_ place: SavedPlace) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    /// Pins any places saved while offline. Called when a signal is available.
    func pinUnpinnedPlaces() async {
        var changed = false
        for place in places where !place.isPinned {
            let pinned = await pin(place)
            if pinned.isPinned, let index = places.firstIndex(where: { $0.id == place.id }) {
                places[index] = pinned
                changed = true
            }
        }
        if changed { persist() }
    }

    private func pin(_ place: SavedPlace) async -> SavedPlace {
        var place = place
        if case .found(let item, let description) = await PlaceResolver.resolve(place.address) {
            let coordinate = item.placemark.coordinate
            place.latitude = coordinate.latitude
            place.longitude = coordinate.longitude
            place.resolvedAddress = description
        }
        return place
    }

    // MARK: - Recents

    func recordTrip(from: String?, to: String, mode: TravelMode) {
        recents.removeAll { $0.from == from && $0.to == to && $0.mode == mode }
        recents.insert(RecentTrip(from: from, to: to, mode: mode, date: Date()), at: 0)
        if recents.count > Self.recentLimit {
            recents.removeLast(recents.count - Self.recentLimit)
        }
        persist()
    }

    func clearRecents() {
        recents.removeAll()
        persist()
    }

    // MARK: - Storage

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            defaults.set(data, forKey: Self.placesKey)
        }
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func normalized(_ text: String) -> String {
        var result = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["my ", "the "] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        return result
    }
}
