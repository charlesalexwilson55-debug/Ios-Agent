import Charts
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
    @State private var now = UsageStore.shared.reading()

    var body: some View {
        Form {
            Section {
                if let top = store.ranked.first, store.totalSeconds > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Used most")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(top.model)
                            .font(.headline)
                        Text("\(percent(top.seconds / store.totalSeconds)) of all generating time")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    chart
                } else {
                    Text("Nothing recorded yet. Usage appears here after the model answers something.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Since \(store.since.formatted(date: .abbreviated, time: .omitted))")
            }

            ForEach(store.ranked) { entry in
                Section(entry.model) {
                    row("Replies and checks", "\(entry.replies)")
                    row("Words read / written", "\(tokens(entry.promptTokens)) / \(tokens(entry.generatedTokens))")
                    row("Time generating", duration(entry.seconds))
                    row("Estimated energy",
                        String(format: "%.2f Wh \u{00B7} about %.1f%% of a charge",
                               entry.estimatedWattHours, entry.estimatedPercentOfCharge))
                    row("Battery drop measured", String(format: "%.0f%%", entry.batteryPercent))
                }
            }

            Section {
                row("Battery", batteryText)
                row("Heat", thermalText)
                row("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
            } header: {
                Text("Right now")
            } footer: {
                Text("Estimates assume about \(Int(UsageStore.estimatedWatts)) W while the model is "
                    + "generating, on a \(Int(UsageStore.batteryWattHours)) Wh battery. The measured drop only "
                    + "counts time on battery power, in whole percent. A hot phone slows the model down to "
                    + "protect itself.")
            }

            Section {
                Button("Reset usage", role: .destructive) { confirmReset = true }
            }
        }
        .onAppear { now = store.reading() }
        .confirmationDialog("Reset all usage figures?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
        }
    }

    private var chart: some View {
        Chart(store.ranked) { entry in
            BarMark(
                x: .value("Minutes", entry.seconds / 60),
                y: .value("Model", entry.model)
            )
            .foregroundStyle(Color.conduitAccent.gradient)
            .annotation(position: .trailing) {
                Text(duration(entry.seconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxisLabel("Minutes generating")
        .frame(height: CGFloat(max(1, store.ranked.count)) * 44 + 30)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private var batteryText: String {
        guard now.level >= 0 else { return "Unknown" }
        let level = Int((now.level * 100).rounded())
        return now.unplugged ? "\(level)%" : "\(level)%, charging or plugged in"
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot, slowing down"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}
