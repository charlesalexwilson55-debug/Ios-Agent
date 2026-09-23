import AVFoundation
import MediaPlayer
import UIKit

/// iOS exposes output-volume changes, not raw button presses. Classify a short
/// burst after it ends: one change navigates, two quick changes toggle the
/// menu, and a held button keeps its normal volume behavior.
@MainActor
final class VolumeKeys {
    static let shared = VolumeKeys()
    static let enabledKey = "conduit.volumeKeys"

    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onDoublePress: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = 0
    private var initialVolume: Float = 0
    private var changes: [(time: TimeInterval, direction: Int)] = []
    private var pendingClassification: Task<Void, Never>?
    private var restoring = false
    private let volumeView = MPVolumeView(frame: CGRect(x: -2_000, y: -2_000, width: 10, height: 10))

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard isEnabled, observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
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
        pendingClassification?.cancel()
        pendingClassification = nil
        changes = []
    }

    private func volumeChanged(to value: Float) {
        let prior = lastVolume
        lastVolume = value
        guard !restoring, value != prior else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if changes.isEmpty { initialVolume = prior }
        changes.append((now, value > prior ? 1 : -1))
        pendingClassification?.cancel()
        pendingClassification = Task { [weak self] in
            // The first repeat from a long press may arrive after 400 ms.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.classify()
        }
    }

    private func classify() {
        defer { changes = []; pendingClassification = nil }
        guard !changes.isEmpty else { return }
        if changes.count == 1 {
            if changes[0].direction > 0 { onUp?() } else { onDown?() }
            setVolume(initialVolume)
        } else if changes.count == 2, changes[1].time - changes[0].time <= 0.45 {
            onDoublePress?()
            setVolume(initialVolume)
        }
        // Three or more changes, or a slow repeat, are a hold. Keep volume.
    }

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
