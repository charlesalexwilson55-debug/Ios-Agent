import Foundation

/// User limits on foreground MLX inference. iOS owns the actual process RAM
/// limit and does not expose a device temperature in degrees to apps.
enum InferencePolicy {
    static let thermalKey = "conduit.power.thermalLimit"
    static let replyTokensKey = "conduit.power.replyTokens"
    static let memoryFractionKey = "conduit.power.cacheFraction"
    static let batterySaverKey = "conduit.power.batterySaver"
    static let batteryModelKey = "conduit.power.batteryModel"

    /// 0: off; 1: stop at fair; 2: stop at serious. Critical always stops.
    static var thermalLimit: Int {
        UserDefaults.standard.object(forKey: thermalKey) as? Int ?? 2
    }

    static var replyTokens: Int {
        let requested = UserDefaults.standard.object(forKey: replyTokensKey) as? Int ?? 4096
        return min(max(requested, 256), 4096)
    }

    static var memoryFraction: Double {
        let requested = UserDefaults.standard.object(forKey: memoryFractionKey) as? Double ?? 1
        return min(max(requested, 0.35), 1)
    }

    static func shouldStop(for state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .critical: return true
        case .serious: return thermalLimit > 0
        case .fair: return thermalLimit == 1
        case .nominal: return false
        @unknown default: return true
        }
    }
}
