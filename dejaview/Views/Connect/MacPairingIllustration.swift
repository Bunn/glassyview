import SwiftUI

/// A small, native illustration shared by setup and the scan confirmation.
struct MacPairingIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var isRecognized = false
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.07))
                .frame(width: 196, height: 196)
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.08), lineWidth: 1)
                .frame(width: 242, height: 242)

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color(.label).opacity(0.9))
                    RoundedRectangle(cornerRadius: 11)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.1, green: 0.23, blue: 0.66), .cyan],
                            startPoint: .bottomLeading, endPoint: .topTrailing
                        ))
                        .padding(6)
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 110, height: 110)
                        .offset(x: -58, y: 36)
                        .clipped()
                    Image(systemName: isRecognized ? "checkmark" : "qrcode")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 196, height: 130)
                .clipShape(.rect(cornerRadius: 15))
                .overlay {
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                }

                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 28, height: 18)
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 72, height: 5)
            }
            .rotationEffect(.degrees(-5))
            .offset(x: -15, y: -3)
            .shadow(color: .blue.opacity(0.14), radius: 14, y: 12)

            phone
                .phaseAnimator(reduceMotion || scenePhase != .active ? [false] : [false, true]) { content, floats in
                    content.offset(y: floats ? -4 : 4)
                } animation: { _ in
                    .easeInOut(duration: 2.8)
                }
                .rotationEffect(.degrees(9))
                .offset(x: 84, y: 33)
                .scaleEffect(hasAppeared ? 1 : 0.8)

            Image(systemName: isRecognized ? "checkmark.circle.fill" : "sparkle")
                .font(.system(size: isRecognized ? 29 : 22, weight: .medium))
                .foregroundStyle(isRecognized ? Color.green : Color.accentColor)
                .background(isRecognized ? Color(.systemBackground) : .clear, in: .circle)
                .offset(x: 101, y: -75)
                .scaleEffect(hasAppeared ? 1 : 0.4)
        }
        .frame(width: 280, height: 248)
        .accessibilityHidden(true)
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.7)) {
                hasAppeared = true
            }
        }
    }

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.systemBackground))
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.09))
                .padding(5)
            VStack(spacing: 13) {
                Capsule()
                    .fill(Color(.label).opacity(0.75))
                    .frame(width: 22, height: 5)
                Image(systemName: isRecognized ? "checkmark.circle.fill" : "viewfinder")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(isRecognized ? Color.green : Color.accentColor)
                Capsule()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 30, height: 4)
            }
        }
        .frame(width: 72, height: 120)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }
}

#Preview {
    MacPairingIllustration()
}
