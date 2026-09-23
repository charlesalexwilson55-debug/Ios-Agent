import Foundation
import Observation
import SwiftUI
import UIKit

/// How much each model has been used, and roughly what it cost in battery.
///
/// iOS does not tell an app how much power it drew, so two figures are kept:
/// an estimate from the time the model spent generating, and the battery
/// percentage that actually went while it generated on battery power. The
/// second is real but coarse, since iOS reports the level in whole percent.
struct ModelUsage: Codable, Identifiable, Hashable {
    var id: String { model }
    var model: String
    var replies = 0
    var promptTokens = 0
    var generatedTokens = 0
    var seconds: Double = 0
    var batteryPercent: Double = 0
    var lastUsed: Date?

    var estimatedWattHours: Double { seconds / 3600 * UsageStore.estimatedWatts }
    var estimatedPercentOfCharge: Double { estimatedWattHours / UsageStore.batteryWattHours * 100 }
}

struct BatteryReading: Sendable {
    let level: Float
    let unplugged: Bool
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    /// Typical draw of an iPhone running a 4B model flat out. An assumption,
    /// shown as one in the app.
    static let estimatedWatts = 6.0
    /// Roughly an iPhone 17 Pro's battery.
    static let batteryWattHours = 16.0

    private static let usageKey = "conduit.usage.models"
    private static let sinceKey = "conduit.usage.since"

    private(set) var usage: [String: ModelUsage] = [:]
    private(set) var since = Date()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let data = UserDefaults.standard.data(forKey: Self.usageKey),
           let saved = try? JSONDecoder().decode([String: ModelUsage].self, from: data) {
            usage = saved
        }
        if let saved = UserDefaults.standard.object(forKey: Self.sinceKey) as? Date {
            since = saved
        } else {
            UserDefaults.standard.set(since, forKey: Self.sinceKey)
        }
    }

    /// Most used first, by time spent generating.
    var ranked: [ModelUsage] {
        usage.values.sorted { $0.seconds > $1.seconds }
    }

    var totalSeconds: Double {
        usage.values.reduce(0) { $0 + $1.seconds }
    }

    func reading() -> BatteryReading {
        let device = UIDevice.current
        return BatteryReading(level: device.batteryLevel, unplugged: device.batteryState == .unplugged)
    }

    func record(model: String, promptTokens: Int, generatedTokens: Int, seconds: Double, start: BatteryReading) {
        var entry = usage[model] ?? ModelUsage(model: model)
        entry.replies += 1
        entry.promptTokens += promptTokens
        entry.generatedTokens += generatedTokens
        entry.seconds += max(0, seconds)
        let end = reading()
        if start.unplugged, end.unplugged, start.level >= 0, end.level >= 0, end.level < start.level {
            entry.batteryPercent += Double(start.level - end.level) * 100
        }
        entry.lastUsed = Date()
        usage[model] = entry
        persist()
    }

    func reset() {
        usage = [:]
        since = Date()
        UserDefaults.standard.set(since, forKey: Self.sinceKey)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
    }
}

/// Settings > Power.
struct PowerSettingsView: View {
    @State private var store = UsageStore.shared
    @State private var confirmReset = false

    private var totalWh: Double {
        store.ranked.reduce(0) { $0 + $1.estimatedWattHours }
    }

    /// Illustrative energy stores; their sizes vary by product and use.
    private let comparisons: [(name: String, symbol: String, wattHours: Double)] = [
        ("9V battery", "battery.25percent", 5),
        ("Two phone charges", "battery.50percent", 32),
        ("Four phone charges", "battery.75percent", 64),
        ("Eight phone charges", "battery.100percent", 128),
        ("Electric car battery example", "car.side", 75_000),
        ("1 MW data center for one hour", "server.rack", 1_000_000),
    ]

    var body: some View {
        Form {
            Section("Total AI use since \(store.since.formatted(date: .abbreviated, time: .omitted))") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.1f%% of a phone charge", totalWh / UsageStore.batteryWattHours * 100))
                        .font(.title2.bold())
                    Text(String(format: "%.2f Wh total energy", totalWh))
                        .font(.headline)
                    Text("About \(Int(UsageStore.estimatedWatts)) W while generating · \(duration(store.totalSeconds)) total")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                ForEach(comparisons.indices, id: \.self) { index in
                    let item = comparisons[index]
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(Color.conduitAccent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            ProgressView(value: min(totalWh / item.wattHours, 1))
                                .tint(Color.conduitAccent)
                            Text(String(format: "%.2f of this example · %.0f Wh", totalWh / item.wattHours, item.wattHours))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Energy in context")
            } footer: {
                Text("Comparisons use rounded example capacities. Energy is estimated from generation time at 6 W; iOS does not provide a direct per-app power meter. A 9V battery stores less energy than a phone charge.")
            }

            if !store.ranked.isEmpty {
                Section("By model") {
                    ForEach(store.ranked) { entry in
                        LabeledContent(entry.model) {
                            Text(String(format: "%.2f Wh", entry.estimatedWattHours))
                        }
                    }
                }
            }

            Section {
                Button("Reset usage", role: .destructive) { confirmReset = true }
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Reset all usage figures?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
        }
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}
