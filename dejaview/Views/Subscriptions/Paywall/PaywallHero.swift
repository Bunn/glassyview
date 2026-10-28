import SwiftUI

/// The app icon's two glass panes. The front pane shows the free-session clock
/// ticking down, then turning into an infinity sign: the heart of Pro.
struct PaywallHero: View {
    let animates: Bool
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var clock = HeroClock.countdown(60)

    var body: some View {
        ZStack {
            PaywallSparkles(animates: animates, isLit: clock == .unlimited)

            GlassPane(style: .back)
                .frame(width: 168, height: 122)
                .rotation3DEffect(.degrees(-16), axis: (x: 0.15, y: 1, z: 0), perspective: 0.6)
                .offset(x: 44, y: hasAppeared ? -34 : -10)
                .opacity(hasAppeared ? 1 : 0)

            GlassPane(style: .front)
                .frame(width: 196, height: 142)
                .overlay { HeroClockFace(clock: clock) }
                .paywallShimmer(isActive: animates && clock == .unlimited, interval: 4.2)
                .rotation3DEffect(.degrees(-12), axis: (x: 0.1, y: 1, z: 0), perspective: 0.6)
                .offset(x: -22, y: hasAppeared ? 22 : 40)
                .scaleEffect(hasAppeared ? 1 : 0.82)
                .opacity(hasAppeared ? 1 : 0)
        }
        .phaseAnimator(animates ? [false, true] : [false]) { content, floats in
            content.offset(y: floats ? -5 : 5)
        } animation: { _ in
            .easeInOut(duration: 3.2)
        }
        .scaleEffect(scale)
        .frame(height: 196 * scale)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: clock == .unlimited) { _, isUnlimited in
            isUnlimited
        }
        .accessibilityElement()
        .accessibilityLabel("Unlimited session time")
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.9, dampingFraction: 0.72)) {
                hasAppeared = true
            }
        }
        .task {
            await runClock()
        }
    }

    private func runClock() async {
        guard !reduceMotion else {
            clock = .unlimited
            return
        }

        do {
            try await Task.sleep(for: .seconds(0.9))
            for second in [59, 58, 57] {
                withAnimation(.snappy(duration: 0.3)) { clock = .countdown(second) }
                try await Task.sleep(for: .seconds(0.42))
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { clock = .unlimited }
        } catch {
            clock = .unlimited
        }
    }
}

enum HeroClock: Equatable {
    case countdown(Int)
    case unlimited
}

private struct HeroClockFace: View {
    let clock: HeroClock

    var body: some View {
        ZStack {
            switch clock {
            case .countdown(let seconds):
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .transition(.blurReplace.combined(with: .scale(0.6)))
            case .unlimited:
                Image(systemName: "infinity")
                    .font(.system(size: 58, weight: .semibold))
                    .symbolEffect(.breathe.plain, options: .repeat(.periodic(delay: 2.4)))
                    .transition(.blurReplace.combined(with: .scale(1.6)))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: PaywallPalette.deepBlue.opacity(0.55), radius: 10, y: 4)
        .offset(y: 6)
    }
}

/// A rounded pane filled like the app icon: pale sky at the top, deep blue below,
/// with a curved highlight and a bright rim.
private struct GlassPane: View {
    enum Style { case front, back }

    let style: Style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        shape
            .fill(fill)
            .overlay {
                // The icon's sweeping arc of light.
                Circle()
                    .stroke(LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.75), .white.opacity(0.1)],
                                           startPoint: .leading, endPoint: .trailing),
                            lineWidth: 2.5)
                    .frame(width: 420, height: 420)
                    .offset(x: 70, y: 250)
                    .opacity(style == .front ? 0.9 : 0.5)
            }
            .overlay {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140)
                    .offset(x: 40, y: 10)
                    .blendMode(.plusLighter)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.25)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1.5)
            }
            .shadow(color: PaywallPalette.deepBlue.opacity(style == .front ? 0.35 : 0.2), radius: 24, y: 14)
    }

    private var fill: LinearGradient {
        switch style {
        case .front:
            LinearGradient(stops: [
                .init(color: PaywallPalette.sky, location: 0),
                .init(color: PaywallPalette.azure, location: 0.38),
                .init(color: PaywallPalette.blue, location: 0.62),
                .init(color: PaywallPalette.deepBlue, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        case .back:
            LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.97),
                                    Color(red: 0.10, green: 0.28, blue: 0.82)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Small sparkles that twinkle around the panes and flare when the clock turns infinite.
private struct PaywallSparkles: View {
    let animates: Bool
    let isLit: Bool

    private static let sparkles: [(x: CGFloat, y: CGFloat, size: CGFloat, delay: Double)] = [
        (-128, -62, 16, 0),
        (122, -92, 12, 0.7),
        (138, 54, 18, 1.3),
        (-140, 70, 10, 1.9),
        (12, -104, 9, 2.4),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.sparkles.indices, id: \.self) { index in
                let sparkle = Self.sparkles[index]

                Image(systemName: "sparkle")
                    .font(.system(size: sparkle.size, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [PaywallPalette.sky, PaywallPalette.indigo],
                                                    startPoint: .top, endPoint: .bottom))
                    .phaseAnimator(animates ? [0.35, 1, 0.35] : [1]) { content, phase in
                        content
                            .scaleEffect(phase)
                            .opacity(0.25 + phase * 0.75)
                    } animation: { phase in
                        .easeInOut(duration: 1.4).delay(phase == 0.35 ? sparkle.delay : 0)
                    }
                    .scaleEffect(isLit ? 1 : 0.4)
                    .opacity(isLit ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(Double(index) * 0.05),
                               value: isLit)
                    .offset(x: sparkle.x, y: sparkle.y)
            }
        }
    }
}

/// The product name and a line that answers why the paywall appeared.
struct PaywallHeadline: View {
    let source: PaywallSource

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "Glassy Desk")
                Text("Pro")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(PaywallPalette.actionGradient, in: .rect(cornerRadius: 12, style: .continuous))
                    .shadow(color: PaywallPalette.deepBlue.opacity(0.3), radius: 8, y: 4)
            }
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .foregroundStyle(PaywallPalette.titleGradient(for: colorScheme))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private var subtitle: LocalizedStringKey {
        switch source {
        case .settings:
            "Stay with your Mac for as long as the job takes."
        case .freeSessionTimer:
            "Keep this session going, with no clock running."
        case .freeSessionCooldown:
            "Skip the break and get back to your Mac now."
        case .sessionLimit:
            "Your free minute is up. Pick up right where you left off."
        }
    }
}
