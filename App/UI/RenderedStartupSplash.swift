import SwiftUI
import UIKit

/// Original rendered chrome artwork, with a restrained motion sequence.
/// A short reveal independent of model loading, which continues in the app.
struct StartupSplash: View {
    let color: Color
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = 0.86
    @State private var stretch: CGFloat = 1
    @State private var halo: Double = 0.35
    @State private var orbOpacity: Double = 1
    @State private var markOpacity: Double = 0
    @State private var finishing = false
    @State private var finale: Task<Void, Never>?
    @State private var washOpacity: Double = 0
    @State private var washExpansion: CGFloat = 0
    @State private var backdropOpacity: Double = 1
    @State private var trail = false

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.72, 310)
            ZStack {
                Color.black.opacity(backdropOpacity).ignoresSafeArea()
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
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 44, height: 5).blur(radius: 3)
                        .offset(x: (position - 0.5) * width * 0.72 + 24)
                        .opacity(trail ? orbOpacity : 0)
                }
                .opacity(markOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The explosion spreads from the orb and becomes one uniform colour.
                Circle().fill(color)
                    .frame(width: 2, height: 2)
                    .scaleEffect(washExpansion * hypot(geometry.size.width, geometry.size.height))
                    .offset(x: (position - 0.5) * width * 0.72)
                    .opacity(washOpacity).allowsHitTesting(false)
                VStack {
                    Spacer()
                    Text("CONDUIT").font(.custom("Archivo-SemiBold", size: 19))
                        .tracking(6).foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 26)
                }.opacity(markOpacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conduit is opening")
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.16)) { markOpacity = 1 }
            finish()
        }
        .onDisappear { finale?.cancel() }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        finale = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(220))
                if !reduceMotion {
                    trail = true
                    withAnimation(.timingCurve(0.2, 0, 0.1, 1, duration: 0.42)) { position = 0.08; halo = 0.6 }
                    try await Task.sleep(for: .milliseconds(420))
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    washOpacity = 1
                    orbOpacity = 0
                    withAnimation(.easeOut(duration: 0.36)) { washExpansion = 1; stretch = 1.015 }
                    try await Task.sleep(for: .milliseconds(360))
                }
                withAnimation(.easeOut(duration: 0.20)) {
                    markOpacity = 0; halo = 0; washOpacity = 0; backdropOpacity = 0; stretch = 1
                }
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                onComplete()
            } catch { /* Leaving the view cancels its completion callback. */ }
        }
    }
}
