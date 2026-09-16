import CoreLocation
import Foundation

/// Current conditions and a short forecast from Open-Meteo, which is free
/// and needs no key.
enum Weather {

    struct Report {
        let now: String
        let forecast: [String]
        let units: String
    }

    enum WeatherError: LocalizedError {
        case badResponse

        var errorDescription: String? { "the forecast could not be read." }
    }

    static func report(for coordinate: CLLocationCoordinate2D) async throws -> Report {
        let imperial = Locale.current.measurementSystem == .us
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily",
                         value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        if imperial {
            items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
            items.append(URLQueryItem(name: "wind_speed_unit", value: "mph"))
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = items
        guard let url = components?.url else { throw WeatherError.badResponse }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any]
        else { throw WeatherError.badResponse }

        let degrees = imperial ? "°F" : "°C"
        let speed = imperial ? "mph" : "km/h"

        let now = "\(format(current["temperature_2m"]))\(degrees) "
            + "(feels like \(format(current["apparent_temperature"]))\(degrees)), "
            + "\(condition(current["weather_code"])), "
            + "humidity \(format(current["relative_humidity_2m"]))%, "
            + "wind \(format(current["wind_speed_10m"])) \(speed)"

        let days = daily["time"] as? [String] ?? []
        let codes = daily["weather_code"] as? [Any] ?? []
        let highs = daily["temperature_2m_max"] as? [Any] ?? []
        let lows = daily["temperature_2m_min"] as? [Any] ?? []
        let rain = daily["precipitation_probability_max"] as? [Any] ?? []

        var forecast: [String] = []
        for (index, day) in days.enumerated() {
            let low = format(lows[safe: index])
            let high = format(highs[safe: index])
            let chance = format(rain[safe: index])
            forecast.append("\(dayName(day, index: index)): \(condition(codes[safe: index])), "
                + "\(low)–\(high)\(degrees), \(chance)% chance of rain")
        }
        return Report(now: now, forecast: forecast, units: "\(degrees), \(speed)")
    }

    // MARK: - Formatting

    private static func format(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "?" }
        return String(Int(number.doubleValue.rounded()))
    }

    private static func condition(_ value: Any?) -> String {
        guard let code = (value as? NSNumber)?.intValue else { return "unknown conditions" }
        return describe(code: code)
    }

    /// WMO weather interpretation codes, as Open-Meteo uses them.
    static func describe(code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71: "light snow"
        case 73: "snow"
        case 75: "heavy snow"
        case 77: "snow grains"
        case 80, 81: "rain showers"
        case 82: "heavy rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unsettled weather"
        }
    }

    private static func dayName(_ isoDay: String, index: Int) -> String {
        switch index {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd"
            guard let date = parser.date(from: isoDay) else { return isoDay }
            return date.formatted(.dateTime.weekday(.wide))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The phone's location, asked for only when the user wants local weather.
@MainActor
final class LocationProvider: NSObject {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var authorization: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var fix: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentLocation() async -> CLLocation? {
        guard authorization == nil, fix == nil else { return nil }

        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
                authorization = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -600 {
            return recent
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            fix = continuation
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finish(with: nil)
            }
        }
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard status != .notDetermined, let authorization else { return }
        self.authorization = nil
        authorization.resume(returning: status)
    }

    fileprivate func finish(with location: CLLocation?) {
        guard let fix else { return }
        self.fix = nil
        fix.resume(returning: location)
    }
}

// @preconcurrency: Core Location calls back on the thread that created the
// manager, which is the main thread here.
extension LocationProvider: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}
