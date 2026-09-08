import SwiftUI

struct FreeSessionCooldownView: View {
    let cooldown: FreeSessionCooldown
    let sessionTitle: String
    let restart: () -> Void
    let purchase: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: cooldown.endDate.addingTimeInterval(-FreeSessionCooldown.duration), by: 1)) { timeline in
                let remainingSeconds = cooldown.remainingSeconds(at: timeline.date)
                let isReady = remainingSeconds == 0

                ScrollView {
                    VStack(spacing: 28) {
                        header(isReady: isReady)

                        countdown(remainingSeconds: remainingSeconds,
                                  progress: cooldown.progress(at: timeline.date))

                        actions(isReady: isReady)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isReady)
                .sensoryFeedback(.success, trigger: isReady) { _, newValue in newValue }
                .onChange(of: isReady) { _, ready in
                    if ready {
                        AccessibilityNotification.Announcement(
                            String(localized: "Your next free session is ready.")
                        ).post()
                    }
                }
            }
        }
        .background {
            LinearGradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.19), .black],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("session.cooldown")
    }

    private func header(isReady: Bool) -> some View {
        VStack(spacing: 12) {
            Label(sessionTitle, systemImage: "desktopcomputer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(isReady ? "Ready when you are" : "Free session complete")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(isReady
                 ? "Your next one-minute session is ready."
                 : "A short break, then you’re back. Start another free session when the timer finishes.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countdown(remainingSeconds: Int, progress: Double) -> some View {
        let isReady = remainingSeconds == 0

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 7)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke((isReady ? Color.mint : .cyan).gradient,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 54, weight: .medium, design: .rounded))
                        .foregroundStyle(.mint)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.8)))
                } else {
                    Text(String(format: "0:%02d", remainingSeconds))
                        .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: remainingSeconds)
                        .transition(.opacity)
                }
            }
            .frame(width: 168, height: 168)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isReady ? "Free session ready" : "Next free session in")
            .accessibilityValue(isReady ? String(localized: "Ready") : remainingTimeDescription(remainingSeconds))
            .accessibilityIdentifier("session.cooldown.timer")

            Text(isReady ? "Let’s get back to your Mac." : "Until your next free session")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isReady ? Color.mint : .secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func actions(isReady: Bool) -> some View {
        VStack(spacing: 20) {
            Button(action: restart) {
                Label(isReady ? "Start New Free Session" : "New Session Available Soon",
                      systemImage: isReady ? "play.fill" : "timer")
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isReady ? Color.black : .primary)
            }
            .buttonStyle(.glassProminent)
            .tint(.cyan)
            .controlSize(.large)
            .disabled(!isReady)
            .accessibilityHint(isReady
                               ? "Reconnects to your Mac for one minute."
                               : "Available when the countdown finishes.")
            .accessibilityIdentifier("session.cooldown.restart")

            VStack(spacing: 10) {
                Text("Skip the wait. Stay as long as you like.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: purchase) {
                    Label("Explore Pro", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityHint("Shows Pro plans for sessions without time limits.")
                .accessibilityIdentifier("session.cooldown.upgrade")
            }

            Button("Back to My Macs", action: close)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("session.cooldown.close")
        }
    }

    private func remainingTimeDescription(_ seconds: Int) -> String {
        if seconds == 1 {
            return String(localized: "\(seconds) second remaining")
        }
        return String(localized: "\(seconds) seconds remaining")
    }
}

#Preview("Countdown") {
    FreeSessionCooldownView(cooldown: FreeSessionCooldown(endDate: .now.addingTimeInterval(30)),
                            sessionTitle: "Studio Mac", restart: {}, purchase: {}, close: {})
        .preferredColorScheme(.dark)
}

#Preview("Ready") {
    FreeSessionCooldownView(cooldown: FreeSessionCooldown(endDate: .distantPast),
                            sessionTitle: "Studio Mac", restart: {}, purchase: {}, close: {})
        .preferredColorScheme(.dark)
}
