import SwiftUI

/// A lightweight vector mark shown while the initial model loads. The finale
/// starts only after startup work finishes, so the animation never hides a
/// model that is still loading.
struct StartupSplash: View {
    let ready: Bool
    let color: Color
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = Date()
    @State private var finaleStarted: Date?
    @State private var extraCrossings = 0

    private let launchEnd = 0.72
    private let crossingTime = 0.27

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(white: 0.035), Color(white: 0.10), Color(white: 0.025)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 25) {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                        let state = sample(at: context.date)
                        conduit(width: min(geometry.size.width * 0.72, 310), state: state)
                    }
                    .frame(height: 118)
                    Text("Conduit")
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .tracking(5)
                        .foregroundStyle(.white.opacity(0.88))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conduit is opening")
        .onAppear {
            appeared = Date()
            if ready { startFinale() }
        }
        .onChange(of: ready) { _, isReady in
            if isReady { startFinale() }
        }
    }

    private struct Frame {
        var position: Double
        var stretch: Double = 0
        var trail: Double = 0
        var blast: Double = 0
    }

    private func sample(at date: Date) -> Frame {
        if reduceMotion { return Frame(position: 0.5) }
        guard let finaleStarted else {
            let phase = date.timeIntervalSince(appeared).truncatingRemainder(dividingBy: 1.8)
            let across = phase < 0.9 ? phase / 0.9 : (1.8 - phase) / 0.9
            return Frame(position: 1 - 0.9 * across)
        }
        let t = max(0, date.timeIntervalSince(finaleStarted))
        if t < 0.37 {
            let progress = t / 0.37
            return Frame(position: 0.8 + 0.2 * progress, stretch: progress)
        }
        if t < launchEnd {
            let progress = (t - 0.37) / (launchEnd - 0.37)
            let fast = 1 - pow(1 - progress, 3)
            return Frame(position: 1 - 0.95 * fast, stretch: 1 - fast, trail: min(progress * 2, 1))
        }
        let impact = launchEnd + Double(extraCrossings) * crossingTime
        if t < impact {
            let step = Int((t - launchEnd) / crossingTime)
            let fraction = ((t - launchEnd) / crossingTime).truncatingRemainder(dividingBy: 1)
            let eased = fraction * fraction * (3 - 2 * fraction)
            let position = step.isMultiple(of: 2) ? 0.05 + 0.9 * eased : 0.95 - 0.9 * eased
            return Frame(position: position, trail: 0.65)
        }
        return Frame(position: 0.05, blast: min((t - impact) / 0.5, 1))
    }

    private func conduit(width: CGFloat, state: Frame) -> some View {
        let height: CGFloat = 76
        let orb: CGFloat = 24
        let x: CGFloat = 20 + (width - 40 - orb) * CGFloat(state.position)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.52), .white, Color(white: 0.37),
                                              Color(white: 0.78)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.75), lineWidth: 1)
                }
                .overlay {
                    Capsule()
                        .fill(Color(white: 0.045))
                        .padding(11)
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1).padding(11)
                        }
                }
                .frame(width: width, height: height)
                .scaleEffect(x: CGFloat(1 + 0.17 * state.stretch), anchor: .leading)
                .shadow(color: .white.opacity(0.2), radius: 20)

            if state.trail > 0 && state.blast == 0 {
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: CGFloat(76 * state.trail), height: 9)
                    .blur(radius: 4)
                    .offset(x: x + orb * 0.55)
            }
            if state.blast < 1 {
                Circle()
                    .fill(RadialGradient(colors: [.white, color, color.opacity(0.65)],
                                         center: .center, startRadius: 1, endRadius: orb * 0.7))
                    .frame(width: orb, height: orb)
                    .shadow(color: color.opacity(0.95), radius: 14)
                    .offset(x: x)
                    .opacity(1 - state.blast)
            }
            if state.blast > 0 {
                ForEach(0..<12, id: \.self) { index in
                    let angle = Double(index) * .pi / 6
                    Circle()
                        .fill(index.isMultiple(of: 3) ? .white : color)
                        .frame(width: index.isMultiple(of: 2) ? 7 : 4,
                               height: index.isMultiple(of: 2) ? 7 : 4)
                        .offset(x: CGFloat(18 + cos(angle) * state.blast * 85),
                                y: CGFloat(sin(angle) * state.blast * 60))
                        .opacity(1 - state.blast)
                }
            }
        }
        .frame(width: width * 1.18, height: height, alignment: .leading)
        .shadow(color: color.opacity(state.blast > 0 ? 0.7 * (1 - state.blast) : 0.18),
                radius: state.blast > 0 ? 38 : 12)
    }

    private func startFinale() {
        guard finaleStarted == nil else { return }
        extraCrossings = Int.random(in: 0..<10) == 0 ? 4 : 0
        finaleStarted = Date()
        let duration = reduceMotion ? 0.2 : launchEnd + Double(extraCrossings) * crossingTime + 0.52
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            onComplete()
        }
    }
}
