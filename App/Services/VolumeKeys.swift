import AVFoundation
import MediaPlayer
import UIKit

/// Opens the menu from the volume buttons.
///
/// iOS gives apps no direct button events, only the volume level, so presses
/// are read from level changes:
/// - a quick up-then-down (or down-then-up) opens the menu, and leaves the
///   volume where it was;
/// - a quick double press of one button opens the menu, and the volume is put
///   back;
/// - holding a button is a steady stream of changes, which is left alone, so
///   holding still changes the volume.
/// A press at full or zero volume changes nothing, so it cannot be seen.
@MainActor
final class VolumeKeys {
    static let shared = VolumeKeys()
    static let enabledKey = "conduit.volumeKeys"

    var onQuickPress: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = 0
    private var changes: [(time: TimeInterval, direction: Int)] = []
    private var pendingDouble: Task<Void, Never>?
    /// Set while Conduit itself is putting the volume back.
    private var restoring = false
    private let volumeView = MPVolumeView(frame: CGRect(x: -2_000, y: -2_000, width: 10, height: 10))

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard isEnabled, observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Ambient and mixable: other apps' audio keeps playing.
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.volumeChanged(to: value) }
        }
        attachVolumeView()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pendingDouble?.cancel()
        changes = []
    }

    private func volumeChanged(to value: Float) {
        defer { lastVolume = value }
        guard !restoring, value != lastVolume else { return }
        let direction = value > lastVolume ? 1 : -1
        let now = ProcessInfo.processInfo.systemUptime
        let previous = changes.last
        changes.append((now, direction))
        changes.removeAll { now - $0.time > 1.5 }
        pendingDouble?.cancel()

        guard let previous else { return }
        let gap = now - previous.time
        let earlier = changes.dropLast(2).last
        let quietBefore = earlier.map { previous.time - $0.time > 0.8 } ?? true

        // Up then down, or down then up.
        if previous.direction != direction, gap < 0.7, quietBefore {
            fire()
            return
        }
        // Two quick presses of the same button, then nothing: not a hold.
        if previous.direction == direction, gap >= 0.08, gap <= 0.45, quietBefore {
            let startVolume = value - Float(direction) * 2 * abs(value - lastVolume)
            pendingDouble = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.fire()
                self?.setVolume(startVolume)
            }
        }
    }

    private func fire() {
        changes = []
        onQuickPress?()
    }

    /// Puts the volume back through the system volume slider, the only way an
    /// app can set it.
    private func setVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        restoring = true
        slider.value = min(max(value, 0), 1)
        slider.sendActions(for: .valueChanged)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.restoring = false
            self?.lastVolume = AVAudioSession.sharedInstance().outputVolume
        }
    }

    private func attachVolumeView() {
        guard volumeView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        window?.addSubview(volumeView)
    }
}
