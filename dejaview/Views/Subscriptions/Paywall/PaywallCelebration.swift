import SwiftUI

/// Shown for a moment once Pro unlocks, whether by purchase, restore, or approval elsewhere.
struct PaywallCelebration: View {
    let doneTitle: LocalizedStringKey
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startDate = Date.now
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            PaywallBackdrop(animates: !reduceMotion)

            if !reduceMotion {
                GlassConfetti(startDate: startDate)
                    .ignoresSafeArea()
            }

            VStack(spacing: 18) {
                ZStack {
                    // A ripple of light that leaves the badge as it lands.
                    Circle()
                        .strokeBorder(PaywallPalette.azure, lineWidth: 3)
                        .frame(width: 112, height: 112)
                        .scaleEffect(hasAppeared && !reduceMotion ? 2.6 : 1)
                        .opacity(hasAppeared && !reduceMotion ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.1).delay(0.15), value: hasAppeared)

                    Circle()
                        .fill(PaywallPalette.actionGradient)
                        .frame(width: 112, height: 112)
                        .shadow(color: PaywallPalette.blue.opacity(0.5), radius: 30, y: 10)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                        }

                    if hasAppeared {
                        Image(systemName: "checkmark")
                            .font(.system(size: 50, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.symbolEffect(.drawOn))
                    }
                }
                .scaleEffect(hasAppeared ? 1 : 0.3)
                .opacity(hasAppeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Welcome to Pro")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(PaywallPalette.titleGradient(for: colorScheme))
                    Text("No more clock. Your Mac is ready whenever you are.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paywallEntrance(1, isVisible: hasAppeared)

                Button(action: done) {
                    Text(doneTitle)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 280, minHeight: 52)
                        .background(PaywallPalette.actionGradient, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .paywallEntrance(2, isVisible: hasAppeared)
                .accessibilityIdentifier("subscription.paywall.celebration.done")
            }
            .padding(32)
        }
        .sensoryFeedback(.success, trigger: hasAppeared) { _, appeared in appeared }
        .onAppear {
            startDate = .now
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.6)) {
                hasAppeared = true
            }
        }
    }
}

/// Little panes of glass in every app icon color, bursting up and drifting down.
private struct GlassConfetti: View {
    let startDate: Date

    private static let colors: [Color] = [
        PaywallPalette.blue,
        Color(red: 0.07, green: 0.16, blue: 0.48),
        Color(red: 0.55, green: 0.56, blue: 0.60),
        Color(red: 0.62, green: 0.38, blue: 0.98),
        Color(red: 0.30, green: 0.88, blue: 0.82),
        Color(red: 0.96, green: 0.52, blue: 0.20),
    ]

    private static let pieces: [Piece] = {
        var generator = SeededGenerator(seed: 0x6C61_7373)
        return (0..<150).map { index in
            Piece(angle: .random(in: -.pi * 0.97 ... -.pi * 0.03, using: &generator),
                  speed: .random(in: 260...760, using: &generator),
                  spin: .random(in: -7...7, using: &generator),
                  size: CGSize(width: .random(in: 9...16, using: &generator),
                               height: .random(in: 12...22, using: &generator)),
                  color: colors[index % colors.count],
                  delay: .random(in: 0...0.3, using: &generator))
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)

            Canvas { context, size in
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.36)
                let gravity = 520.0
                let lifetime = 4.0

                for piece in Self.pieces {
                    let t = max(0, elapsed - piece.delay)
                    guard t > 0, t < lifetime else { continue }

                    // Air drag slows the burst quickly, so the panes float down rather than fly off.
                    let travel = (1 - exp(-2.6 * t)) / 2.6
                    let flutter = sin(t * 4 + piece.spin) * 14 * min(1, t)
                    let x = origin.x + cos(piece.angle) * piece.speed * travel + flutter
                    let y = origin.y + sin(piece.angle) * piece.speed * travel + 0.5 * gravity * t * t * 0.5
                    let fade = min(1, max(0, (lifetime - t) / 0.9))

                    var pane = context
                    pane.opacity = fade
                    pane.translateBy(x: x, y: y)
                    pane.rotate(by: .radians(piece.spin * t))
                    // Flip around the vertical axis by squashing the width, like a tumbling card.
                    pane.scaleBy(x: abs(cos(piece.spin * t * 0.7)) * 0.8 + 0.2, y: 1)

                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2,
                                      width: piece.size.width, height: piece.size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 2.5)
                    pane.fill(path, with: .linearGradient(
                        Gradient(colors: [piece.color.opacity(0.65), piece.color]),
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)))
                    pane.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 0.75)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Piece {
        let angle: Double
        let speed: Double
        let spin: Double
        let size: CGSize
        let color: Color
        let delay: Double
    }
}

/// Keeps the confetti layout identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
