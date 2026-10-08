import SwiftUI

/// Original rendered chrome artwork, with a restrained motion sequence.
/// Opening completes only after the model's startup work finishes.
struct StartupSplash: View {
    let ready: Bool
    let color: Color
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = 0.86
    @State private var stretch: CGFloat = 1
    @State private var halo: Double = 0.35
    @State private var orbOpacity: Double = 1
    @State private var markOpacity: Double = 0
    @State private var finishing = false
    @State private var appeared = false
    @State private var finale: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.72, 310)
            ZStack {
                Color(white: 0.025).ignoresSafeArea()
                ZStack {
                    Image("StartupConduitChrome")
                        .resizable().scaledToFit()
                        .frame(width: width, height: width * 0.4)
                        .scaleEffect(x: stretch, y: 1)
                    Circle()
                        .fill(color.opacity(halo))
                        .frame(width: 40, height: 40).blur(radius: 15)
                        .offset(x: (position - 0.5) * width * 0.72)
                    Circle()
                        .fill(RadialGradient(colors: [.white, color, color.opacity(0.85)],
                                             center: .topLeading, startRadius: 0, endRadius: 13))
                        .frame(width: 13, height: 13)
                        .shadow(color: color.opacity(0.8), radius: 6)
                        .offset(x: (position - 0.5) * width * 0.72)
                        .opacity(orbOpacity)
                }
                .opacity(markOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conduit is opening")
        .onAppear {
            appeared = true
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.24)) { markOpacity = 1 }
            if ready { finish() }
        }
        .onChange(of: ready) { _, value in if value && appeared { finish() } }
        .onDisappear { finale?.cancel() }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        finale = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(180))
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.18)) { position = 0.96; stretch = 1.035; halo = 0.55 }
                    try await Task.sleep(for: .milliseconds(180))
                    withAnimation(.interpolatingSpring(stiffness: 240, damping: 24)) { position = 0.08; stretch = 1 }
                    try await Task.sleep(for: .milliseconds(290))
                    if Int.random(in: 0..<10) == 0 {
                        for destination in [CGFloat(0.92), CGFloat(0.08)] {
                            withAnimation(.easeInOut(duration: 0.22)) { position = destination }
                            try await Task.sleep(for: .milliseconds(240))
                        }
                    }
                    withAnimation(.easeOut(duration: 0.16)) { halo = 0.85; orbOpacity = 0 }
                    try await Task.sleep(for: .milliseconds(160))
                }
                withAnimation(.easeOut(duration: 0.18)) { markOpacity = 0; halo = 0 }
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                onComplete()
            } catch { /* Leaving the view cancels its completion callback. */ }
        }
    }
}
