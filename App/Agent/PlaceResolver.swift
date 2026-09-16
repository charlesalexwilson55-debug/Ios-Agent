import CoreLocation
import Foundation
import MapKit

/// Turns what the user said into an exact place before Maps sees it.
///
/// Handing Maps a free-text address lets Maps guess, and it guesses wrong
/// when the same street name exists in several towns: the user named one
/// town and Maps opened the street in another. So every place is looked up
/// with MapKit first, and a result is only accepted when it contains the
/// distinguishing words the user gave (street name, town, suburb). Maps is
/// then opened with the resolved places, so it cannot re-interpret them.
@MainActor
enum PlaceResolver {

    enum Resolution {
        case found(MKMapItem, description: String)
        /// Results came back, but none contained what the user asked for.
        case ambiguous([String])
        case notFound
        /// The search itself failed, which almost always means no signal.
        case searchFailed
    }

    static func resolve(_ query: String) async -> Resolution {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region = nearbyRegion() { request.region = region }

        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .notFound
        } catch {
            return .searchFailed
        }
        guard !items.isEmpty else { return .notFound }

        let wanted = keywords(query)
        var best: MKMapItem?
        var bestScore = -1
        for item in items {
            let available = searchableWords(item)
            let score = wanted.filter { available.contains($0) }.count
            if score > bestScore {
                best = item
                bestScore = score
            }
        }
        // Everything must match. With three or more words one miss is
        // tolerated, since a region name can be written several ways.
        let needed = wanted.count >= 3 ? wanted.count - 1 : wanted.count
        if let best, bestScore >= needed {
            return .found(best, description: describe(best))
        }
        return .ambiguous(items.prefix(3).map { describe($0) })
    }

    /// One line a person can read: "Name, full address".
    static func describe(_ item: MKMapItem) -> String {
        let name = item.name ?? ""
        let address = item.placemark.title ?? ""
        if address.isEmpty { return name }
        if name.isEmpty || address.hasPrefix(name) { return address }
        return "\(name), \(address)"
    }

    // MARK: - Matching

    /// Words that say what kind of place it is, not which one.
    private static let generic: Set<String> = [
        "street", "road", "avenue", "lane", "drive", "close", "court", "place", "crescent",
        "terrace", "way", "highway", "parade", "grove", "square", "boulevard", "station",
        "the", "and", "near", "from", "to", "in", "at", "of", "my", "uk", "usa", "us",
    ]

    private static let abbreviations: [String: String] = [
        "st": "street", "rd": "road", "ave": "avenue", "av": "avenue", "ln": "lane",
        "dr": "drive", "cl": "close", "ct": "court", "pl": "place", "cres": "crescent",
        "tce": "terrace", "hwy": "highway", "pde": "parade", "sq": "square",
        "blvd": "boulevard", "stn": "station", "mt": "mount",
    ]

    /// Australian states come back abbreviated; users often spell them out.
    private static let regionNames: [String: String] = [
        "vic": "victoria", "nsw": "new south wales", "qld": "queensland",
        "sa": "south australia", "wa": "western australia", "tas": "tasmania",
        "nt": "northern territory", "act": "australian capital territory",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { abbreviations[String($0)] ?? String($0) }
    }

    /// The words a result must contain. House numbers are left out: a
    /// result for the right street in the right town is still the right
    /// place even when MapKit drops the number.
    static func keywords(_ query: String) -> [String] {
        words(query).filter { word in
            !generic.contains(word) && word.count >= 3 && word.allSatisfy(\.isLetter)
        }
    }

    private static func searchableWords(_ item: MKMapItem) -> Set<String> {
        let mark = item.placemark
        var parts = [item.name, mark.title, mark.thoroughfare, mark.subLocality, mark.locality,
                     mark.subAdministrativeArea, mark.administrativeArea, mark.postalCode,
                     mark.country].compactMap { $0 }
        if let area = mark.administrativeArea?.lowercased(), let full = regionNames[area] {
            parts.append(full)
        }
        return Set(words(parts.joined(separator: " ")))
    }

    /// Biases the search towards where the user is, when Conduit already has
    /// location access. It never asks: a permission prompt in the middle of
    /// opening Maps would be confusing, and the town in the query is enough.
    private static func nearbyRegion() -> MKCoordinateRegion? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard let location = manager.location else { return nil }
            return MKCoordinateRegion(center: location.coordinate,
                                      latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        default:
            return nil
        }
    }
}
