import SwiftUI

/// The same devices move from a mirrored desktop into a short pairing demo.
struct OnboardingIllustration: View {
    let page: OnboardingPage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAppeared = false
    @State private var pairingComplete = false

    private var isPairing: Bool { page == .pair }
    private var animates: Bool { !reduceMotion && scenePhase == .active }
    private var accent: Color { isPairing ? .mint : .cyan }

    var body: some View {
        GeometryReader { geometry in
            scene
                .frame(width: 360, height: 300)
                .scaleEffect(min(geometry.size.width / 360, geometry.size.height / 300))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.85, dampingFraction: 0.78)) {
                hasAppeared = true
            }
        }
        .task(id: page) {
            pairingComplete = false
            guard isPairing else { return }
            if reduceMotion {
                pairingComplete = true
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.3))
            } catch {
                return
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                pairingComplete = true
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.82), value: page)
    }

    private var scene: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.14))
                .frame(width: 240, height: 240)
                .blur(radius: 35)
                .offset(x: isPairing ? 30 : -20, y: -10)

            Circle()
                .strokeBorder(accent.opacity(0.12), lineWidth: 1)
                .frame(width: 290, height: 290)
                .scaleEffect(isPairing ? 0.95 : 1)

            monitor
                .rotationEffect(.degrees(isPairing ? -2 : -7))
                .offset(x: isPairing ? -32 : -22, y: -23)
                .scaleEffect(hasAppeared ? 1 : 0.86)
                .opacity(hasAppeared ? 1 : 0)

            phone
                .phaseAnimator(animates ? [false, true] : [false]) { content, floats in
                    content.offset(y: floats ? -4 : 4)
                } animation: { _ in
                    .easeInOut(duration: 3)
                }
                .rotationEffect(.degrees(isPairing ? 3 : 10))
                .offset(x: isPairing ? 93 : 99, y: isPairing ? 38 : 44)
                .scaleEffect(hasAppeared ? 1 : 0.7)
                .opacity(hasAppeared ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.75).delay(0.12),
                           value: hasAppeared)

            Image(systemName: isPairing ? "link" : "cursorarrow.click")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 17))
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                }
                .rotationEffect(.degrees(isPairing ? 5 : -8))
                .offset(x: -119, y: 82)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .scaleEffect(hasAppeared ? 1 : 0.5)
                .opacity(hasAppeared ? 1 : 0)

            Image(systemName: "sparkle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(accent.opacity(0.8))
                .rotationEffect(.degrees(isPairing ? 90 : 0))
                .offset(x: 125, y: -110)
        }
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.08, green: 0.13, blue: 0.23))

                OnboardingDesktopArtwork()
                    .blur(radius: isPairing ? 2 : 0)
                    .padding(7)
                    .clipShape(.rect(cornerRadius: 20))

                Image(systemName: "qrcode")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(Color(red: 0.03, green: 0.15, blue: 0.25))
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 14))
                    .scaleEffect(isPairing ? 1 : 0.6)
                    .opacity(isPairing ? 1 : 0)
            }
            .frame(width: 250, height: 169)
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1.5)
            }

            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 32, height: 23)

            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 83, height: 6)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 18)
    }

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25)
                .fill(Color(red: 0.055, green: 0.10, blue: 0.18))

            OnboardingDesktopArtwork()
                .opacity(isPairing ? 0.2 : 1)
                .padding(6)
                .clipShape(.rect(cornerRadius: 25))

            if isPairing {
                ZStack {
                    Image(systemName: pairingComplete ? "checkmark.circle.fill" : "viewfinder")
                        .font(.system(size: 45, weight: .light))
                        .foregroundStyle(pairingComplete ? .mint : .white)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))

                    Capsule()
                        .fill(.cyan)
                        .frame(width: 42, height: 2)
                        .shadow(color: .cyan.opacity(0.7), radius: 5)
                        .phaseAnimator(animates && !pairingComplete ? [false, true] : [false]) { content, scans in
                            content.offset(y: scans ? 19 : -19)
                        } animation: { _ in
                            .easeInOut(duration: 0.65)
                        }
                        .opacity(pairingComplete ? 0 : 1)
                }
                .transition(.opacity)
            }

            VStack {
                Capsule()
                    .fill(.black.opacity(0.75))
                    .frame(width: 30, height: 7)
                    .padding(.top, 12)
                Spacer()
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: 30, height: 3)
                    .padding(.bottom, 11)
            }
        }
        .frame(width: 100, height: 185)
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.18)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 14)
    }
}

private struct OnboardingDesktopArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.19, green: 0.14, blue: 0.64), .blue, .cyan],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                Ellipse()
                    .fill(.white.opacity(0.15))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.75)
                    .rotationEffect(.degrees(-35))
                    .offset(x: geometry.size.width * 0.3, y: geometry.size.height * 0.3)

                VStack(alignment: .leading, spacing: geometry.size.height * 0.07) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { _ in
                            Circle().fill(.white.opacity(0.7)).frame(width: 4, height: 4)
                        }
                    }

                    HStack(alignment: .top, spacing: geometry.size.width * 0.04) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.18))
                            .frame(width: geometry.size.width * 0.15)

                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(.white.opacity(0.7)).frame(height: 5)
                            Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                            Capsule().fill(.white.opacity(0.25))
                                .frame(width: geometry.size.width * 0.2, height: 4)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(geometry.size.width * 0.045)
                .frame(width: geometry.size.width * 0.72, height: geometry.size.height * 0.62)
                .background(.white.opacity(0.14), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 0.7)
                }
                .rotationEffect(.degrees(-3))
            }
            .clipShape(.rect(cornerRadius: 14))
        }
    }
}

#Preview("Welcome") {
    OnboardingIllustration(page: .welcome)
        .frame(width: 360, height: 300)
        .preferredColorScheme(.dark)
        .background(Color(red: 0.025, green: 0.10, blue: 0.21))
}

#Preview("Pairing") {
    OnboardingIllustration(page: .pair)
        .frame(width: 360, height: 300)
        .preferredColorScheme(.dark)
        .background(Color(red: 0.025, green: 0.10, blue: 0.21))
}
