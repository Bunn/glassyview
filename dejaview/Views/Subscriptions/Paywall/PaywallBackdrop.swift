import SwiftUI

/// A slowly drifting mesh of the icon's blues behind the whole paywall.
struct PaywallBackdrop: View {
    let animates: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0

            MeshGradient(width: 3, height: 3,
                         points: points(at: time),
                         colors: colors,
                         smoothsColors: true)
        }
        .overlay(alignment: .top) {
            // A soft pool of light under the hero panes.
            RadialGradient(colors: [glowColor, glowColor.opacity(0)],
                           center: .center,
                           startRadius: 0,
                           endRadius: 260)
                .frame(height: 520)
                .offset(y: -80)
                .blendMode(colorScheme == .dark ? .plusLighter : .normal)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var glowColor: Color {
        colorScheme == .dark
            ? PaywallPalette.blue.opacity(0.32)
            : .white.opacity(0.85)
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            [
                Color(red: 0.01, green: 0.02, blue: 0.09), Color(red: 0.03, green: 0.09, blue: 0.30), Color(red: 0.05, green: 0.04, blue: 0.20),
                Color(red: 0.02, green: 0.10, blue: 0.36), Color(red: 0.01, green: 0.04, blue: 0.16), Color(red: 0.10, green: 0.06, blue: 0.30),
                Color(red: 0.00, green: 0.01, blue: 0.07), Color(red: 0.02, green: 0.07, blue: 0.24), Color(red: 0.01, green: 0.02, blue: 0.10),
            ]
        } else {
            [
                Color(red: 0.91, green: 0.95, blue: 1.00), Color(red: 0.84, green: 0.91, blue: 1.00), Color(red: 0.93, green: 0.91, blue: 1.00),
                Color(red: 0.86, green: 0.93, blue: 1.00), Color(red: 0.97, green: 0.98, blue: 1.00), Color(red: 0.91, green: 0.90, blue: 1.00),
                Color(red: 0.95, green: 0.97, blue: 1.00), Color(red: 0.88, green: 0.93, blue: 1.00), Color(red: 0.97, green: 0.97, blue: 1.00),
            ]
        }
    }

    /// Corners stay pinned; edges and the center wander on slow, out-of-phase orbits.
    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(sin(time * speed + phase) * amount)
        }

        return [
            [0, 0], [0.5 + wave(0.21, 0, 0.12), 0], [1, 0],
            [0, 0.5 + wave(0.17, 1.3, 0.10)],
            [0.5 + wave(0.23, 2.1, 0.14), 0.45 + wave(0.19, 0.4, 0.12)],
            [1, 0.5 + wave(0.15, 3.0, 0.10)],
            [0, 1], [0.5 + wave(0.18, 4.2, 0.14), 1], [1, 1],
        ]
    }
}
