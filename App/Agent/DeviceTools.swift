import Foundation
import MapKit
import UIKit

/// Time, clipboard, app launching, maps, media and Shortcuts.
///
/// Shortcuts is the important one. iOS gives a third-party app no public API
/// to set an alarm, toggle a Focus mode, change Wi-Fi, or touch most system
/// state. The Shortcuts app *can* do many of those things, and an app is
/// allowed to run a shortcut by name. So `run_shortcut` is the sanctioned
/// escape hatch for everything the sandbox otherwise forbids: the user builds
/// the shortcut once, and the model calls it by name forever after.
@MainActor
final class DeviceTools: ToolProviding {

    /// Natural-language app names mapped to the URL that opens them.
    ///
    /// Frozen table rather than string munging: the model says "the clock app",
    /// "Clock", "timer" and "alarms" for the same destination, and a lookup
    /// table is both predictable and cheap to extend.
    private static let appTargets: [String: String] = [
        "calendar": "calshow://",
        "reminders": "x-apple-reminderkit://",
        "notes": "mobilenotes://",
        "clock": "clock-alarm://",
        "alarms": "clock-alarm://",
        "timer": "clock-alarm://",
        "camera": "camera://",
        "photos": "photos-redirect://",
        "maps": "maps://",
        "music": "music://",
        "podcasts": "podcasts://",
        "phone": "tel://",
        "messages": "sms://",
        "mail": "mailto://",
        "facetime": "facetime://",
        "settings": "App-Prefs://",
        "shortcuts": "shortcuts://",
        "find my": "findmy://",
        "health": "x-apple-health://",
        "wallet": "shoebox://",
        "app store": "itms-apps://",
        "safari": "https://www.apple.com",
        "whatsapp": "whatsapp://",
        "spotify": "spotify://",
        "gmail": "googlegmail://",
    ]

    let specs: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_current_time",
            description: "Get the current date, time, weekday and time zone. Call this FIRST "
                + "whenever the user says anything relative such as tomorrow, tonight, next "
                + "Friday or in two hours. You have no clock of your own and will otherwise "
                + "guess the date wrongly.",
            params: [],
            friction: .silent,
            category: "device"
        ),
        ToolDescriptor(
            name: "run_shortcut",
            description: "Run one of the user's shortcuts from the Shortcuts app by name. This is "
                + "how you reach things iOS does not expose to apps directly: setting an alarm, "
                + "toggling a Focus mode, controlling smart home devices, changing settings. "
                + "The shortcut must already exist on the device and the name must match exactly. "
                + "This leaves Conduit and switches to Shortcuts.",
            params: [
                .required("name", .string, "The exact name of the existing shortcut."),
                .optional("input", .string, "Text to pass into the shortcut as its input."),
            ],
            friction: .leavesApp,
            category: "shortcuts"
        ),
        ToolDescriptor(
            name: "open_app",
            description: "Open another app on the phone, optionally with a search term. "
                + "This switches away from Conduit.",
            params: [
                .required("app", .string, "Which app to open.",
                          allowedValues: [
                              "calendar", "reminders", "notes", "clock", "camera", "photos",
                              "maps", "music", "podcasts", "phone", "messages", "mail",
                              "facetime", "settings", "shortcuts", "find my", "health",
                              "wallet", "app store", "safari", "whatsapp", "spotify", "gmail",
                          ]),
            ],
            friction: .leavesApp,
            category: "device"
        ),
        ToolDescriptor(
            name: "get_directions",
            description: "Open Maps with directions between two places. Copy each address exactly "
                + "as the user gave it, including the street number, town or suburb and postcode. "
                + "Saved places such as home or work can be given by name. Leave origin out to "
                + "start from the user's current location. Works offline in areas the user has "
                + "downloaded in Apple Maps.",
            params: [
                .required("destination", .string,
                          "Where to go: the full address or place name, including the town."),
                .optional("origin", .string,
                          "Where to start: the full address including the town. "
                              + "Omit to start from the current location."),
                .optional("mode", .string, "Travel mode.",
                          allowedValues: ["driving", "walking", "transit", "cycling"]),
            ],
            friction: .leavesApp,
            category: "device"
        ),
        ToolDescriptor(
            name: "play_music",
            description: "Open Music and search for something to play.",
            params: [
                .required("query", .string, "Artist, album, song or playlist to look for."),
            ],
            friction: .leavesApp,
            category: "device"
        ),
        ToolDescriptor(
            name: "open_in_browser",
            description: "Open a web page, or a search, in Safari for the user to look at. This "
                + "leaves Conduit. Only call it when the user asks to open or see something in "
                + "the browser. To answer a question, use web_search and read_page instead.",
            params: [
                .required("target", .string,
                          "A full https:// link, or the words to search for."),
            ],
            friction: .leavesApp,
            category: "device"
        ),
        ToolDescriptor(
            name: "copy_to_clipboard",
            description: "Put text on the clipboard so the user can paste it anywhere. "
                + "Useful when no tool can complete a task directly: prepare the text and "
                + "let the user paste it.",
            params: [
                .required("text", .string, "The text to copy."),
            ],
            friction: .silent,
            category: "device"
        ),
    ]

    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        switch name {
        case "get_current_time": return currentTime()
        case "run_shortcut": return await runShortcut(arguments)
        case "open_app": return await openApp(arguments)
        case "get_directions": return await directions(arguments)
        case "play_music": return await playMusic(arguments)
        case "open_in_browser": return await openInBrowser(arguments)
        case "copy_to_clipboard": return copyToClipboard(arguments)
        default: return .failure(name, "DeviceTools cannot handle \(name).")
        }
    }

    // MARK: - Time

    private func currentTime() -> ToolOutcome {
        let now = Date()
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.dateFormat = "EEEE"
        return .success("get_current_time", "It is \(DateParsing.display(now))",
                        detail: [
                            "iso": DateParsing.iso(now),
                            "weekday": weekday.string(from: now),
                            "time_zone": TimeZone.current.identifier,
                            "utc_offset_hours": String(TimeZone.current.secondsFromGMT() / 3600),
                        ])
    }

    // MARK: - Shortcuts

    private func runShortcut(_ args: ArgumentValue) async -> ToolOutcome {
        guard let name = args.string("name"), !name.isEmpty else {
            return .badArgument("run_shortcut", "name", "the exact name of an existing shortcut")
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var query = [URLQueryItem(name: "name", value: name)]
        if let input = args.string("input"), !input.isEmpty {
            query.append(URLQueryItem(name: "input", value: "text"))
            query.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = query

        guard let url = components.url else {
            return .failure("run_shortcut", "Could not build a URL for shortcut \(name).")
        }
        guard await ComposePresenter.open(url) else {
            return .failure("run_shortcut",
                            "iOS would not open the Shortcuts app. Check that Shortcuts is installed.")
        }
        // A successful open only means Shortcuts was launched. If the name does
        // not match, Shortcuts itself shows the error and the app never hears
        // about it, so this must not be reported as the shortcut having run.
        return .handedOff("run_shortcut", "Asked Shortcuts to run \(name)",
                       detail: [
                           "shortcut": name,
                           "outcome": "Shortcuts was opened and asked to run this shortcut. "
                               + "Conduit cannot see the result. If the name does not match one "
                               + "of the user's shortcuts, Shortcuts will show an error. Ask the "
                               + "user whether it worked rather than assuming it did.",
                       ])
    }

    // MARK: - Apps and links

    private func openApp(_ args: ArgumentValue) async -> ToolOutcome {
        guard let requested = args.string("app")?.lowercased() else {
            return .badArgument("open_app", "app", "the name of an app to open")
        }
        guard let target = Self.appTargets[requested]
            ?? Self.appTargets.first(where: { requested.contains($0.key) })?.value
        else {
            let known = Self.appTargets.keys.sorted().joined(separator: ", ")
            return .failure("open_app",
                            "Conduit cannot open \(requested). Apps it can open: \(known).")
        }
        guard let url = URL(string: target) else {
            return .failure("open_app", "\(target) is not a valid URL.")
        }
        guard await ComposePresenter.open(url) else {
            return .failure("open_app",
                            "iOS refused to open \(requested). The app may not be installed, or "
                                + "it may not accept being opened this way.")
        }
        return .handedOff("open_app", "Opening \(requested)",
                       detail: ["app": requested, "outcome": "Conduit is now in the background"])
    }

    private func directions(_ args: ArgumentValue) async -> ToolOutcome {
        guard let destination = args.string("destination")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !destination.isEmpty
        else {
            return .badArgument("get_directions", "destination", "an address or place name")
        }
        let mode = TravelMode(rawValue: args.string("mode")?.lowercased() ?? "") ?? .driving

        switch await DirectionsService.open(from: args.string("origin"), to: destination, mode: mode) {
        case .opened(let from, let to, let exact):
            var detail = ["from": from, "to": to, "mode": mode.rawValue]
            if !exact {
                detail["offline"] = "There was no signal, so Maps was given the place names to "
                    + "find in its downloaded offline maps. Tell the user to check that Maps "
                    + "picked the right places."
            }
            return .handedOff("get_directions", "Directions from \(from) to \(to)", detail: detail)
        case .unresolved(let role, let query, let options):
            return Self.unresolved(role, query, options)
        case .failed(let reason):
            return .failure("get_directions", reason)
        }
    }

    /// Refuses to open Maps on a guess, and gives the model what it needs to ask.
    private static func unresolved(_ role: String, _ query: String, _ options: [String]) -> ToolOutcome {
        let found = options.isEmpty
            ? "Nothing matched it."
            : "The closest matches were: \(options.joined(separator: "; "))."
        return .failure("get_directions",
                        "Could not find the \(role) \"\(query)\" exactly. \(found) Ask the user "
                            + "which place they meant, or for the town and postcode. "
                            + "Do not open Maps with a guess.")
    }

    private func playMusic(_ args: ArgumentValue) async -> ToolOutcome {
        guard let query = args.string("query"), !query.isEmpty else {
            return .badArgument("play_music", "query", "something to search for")
        }
        // The Music app claims music.apple.com links, and a universal link is
        // far more reliable than the undocumented music:// search host.
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: query)]
        guard let url = components?.url, await ComposePresenter.open(url) else {
            return .failure("play_music", "Could not open Music for \(query).")
        }
        return .handedOff("play_music", "Searching Music for \(query)",
                       detail: [
                           "query": query,
                           "outcome": "Music opened at the search results. Conduit cannot press "
                               + "play for the user.",
                       ])
    }

    private func openInBrowser(_ args: ArgumentValue) async -> ToolOutcome {
        guard let target = args.string("target")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            return .badArgument("open_in_browser", "target", "a link or words to search for")
        }
        let url: URL?
        if let link = URL(string: target), let scheme = link.scheme?.lowercased(),
           scheme == "https" || scheme == "http", link.host != nil {
            url = link
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: target)]
            url = components?.url
        }
        guard let url, await ComposePresenter.open(url) else {
            return .failure("open_in_browser", "Could not open the browser.")
        }
        return .handedOff("open_in_browser", "Opened \(url.host ?? target) in the browser",
                          detail: ["opened": url.absoluteString])
    }

    private func copyToClipboard(_ args: ArgumentValue) -> ToolOutcome {
        guard let text = args.string("text"), !text.isEmpty else {
            return .badArgument("copy_to_clipboard", "text", "the text to copy")
        }
        UIPasteboard.general.string = text
        return .success("copy_to_clipboard", "Copied to the clipboard",
                        detail: ["characters": String(text.count)])
    }
}
