import RoyalVNCKit
import SwiftUI

struct ExternalSessionControllerView<Session: RemoteSessionControlling>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let session: Session
    let sessionTitle: String
    @Binding var heldModifierKeys: Set<RemoteModifierKey>
    @Binding var isKeyboardFocused: Bool
    let stopControllerMode: () -> Void

    @State private var keyboardFocusRequest = 0
    @State private var trackpadZoomScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 14) {
            if verticalSizeClass == .compact {
                compactHeader
            } else {
                header
            }

            trackpad

            if verticalSizeClass != .compact {
                SessionShortcutStrip(session: session,
                                     heldModifierKeys: $heldModifierKeys,
                                     onSend: requestKeyboardFocus)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, verticalSizeClass == .compact ? 56 : 74)
        .background {
            LinearGradient(colors: [.black, Color(uiColor: .secondarySystemBackground)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            RemoteSoftwareKeyboardInput(focusRequest: keyboardFocusRequest,
                                        isFocused: $isKeyboardFocused,
                                        onInsertText: sendText,
                                        onDeleteBackward: deleteBackward,
                                        onReturn: sendReturn)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .task {
            await Task.yield()
            isKeyboardFocused = true
            requestKeyboardFocus()
        }
    }

    private var compactHeader: some View {
        HStack {
            Label(sessionTitle, systemImage: "rectangle.connected.to.line.below")
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button("Show Here", systemImage: "rectangle.on.rectangle", action: stopControllerMode)
                .buttonStyle(.glass)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text("Remote desktop is on the external display")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button("Show Here", systemImage: "rectangle.on.rectangle", action: stopControllerMode)
                .buttonStyle(.glass)
        }
    }

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(.white.opacity(0.08))
                .stroke(.white.opacity(0.18), lineWidth: 1)

            RemoteDesktopView(session: session,
                              selectedFramebufferFrame: session.selectedDisplayFrame,
                              zoomScale: $trackpadZoomScale,
                              followsCursor: false,
                              acceptsHardwareKeyboardInput: false,
                              showsFramebuffer: false,
                              showsCursorOverlay: false,
                              touchModeOverride: .trackpad)
                .clipShape(.rect(cornerRadius: 28))

            VStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.largeTitle)

                Text("Trackpad")
                    .font(.headline)

                Text("Move with one finger • Scroll with two • Two-finger tap to right-click")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: verticalSizeClass == .compact ? 96 : 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote trackpad")
        .accessibilityHint("Move with one finger, scroll with two fingers, or tap with two fingers to right-click.")
    }

    private func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        session.sendText(text)
    }

    private func sendReturn() {
        session.sendReturn()
    }

    private func deleteBackward() {
        session.sendKey(.delete)
    }

    private func requestKeyboardFocus() {
        guard isKeyboardFocused else { return }
        keyboardFocusRequest += 1
    }
}
