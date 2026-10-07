import RoyalVNCKit
import SwiftUI

struct ExternalSessionControllerView<Session: RemoteSessionControlling>: View {
    enum Presentation: Hashable {
        case externalDisplay
        case folded
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let session: Session
    let sessionTitle: String
    @Binding var heldModifierKeys: Set<RemoteModifierKey>
    @Binding var isKeyboardFocused: Bool
    let stopControllerMode: () -> Void
    var presentation: Presentation = .externalDisplay
    var allowsHardwareKeyboardInput = true

    @State private var keyboardFocusRequest = 0
    @State private var trackpadZoomScale: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let isFolded = presentation == .folded
            let compact = isFolded
                ? geometry.size.height < 220 || geometry.size.width < 320
                : verticalSizeClass == .compact || geometry.size.height < 400
            VStack(spacing: compact ? 8 : 14) {
                if !isFolded {
                    if compact {
                        compactHeader
                    } else {
                        header
                    }
                }

                // The system keyboard can leave only a small portion of the
                // controller pane. Keep its input surface inside that local area.
                trackpad(compact: compact)
                    .frame(minHeight: isFolded ? min(44, max(0, geometry.size.height - 8)) : 44)

                if !isFolded && !compact {
                    SessionShortcutStrip(session: session,
                                         heldModifierKeys: $heldModifierKeys,
                                         onSend: requestKeyboardFocus)
                }
            }
            .padding(.horizontal, isFolded ? min(8, max(0, geometry.size.width / 2)) : 16)
            .padding(.top, isFolded ? min(4, max(0, geometry.size.height / 2)) : (compact ? 56 : 74))
            .padding(.bottom, isFolded ? min(4, max(0, geometry.size.height / 2)) : 0)
        }
        .background {
            LinearGradient(colors: [.black, Color(uiColor: .secondarySystemBackground)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea(edges: presentation == .externalDisplay ? .all : [])
        }
        .overlay(alignment: .bottom) {
            RemoteSoftwareKeyboardInput(focusRequest: keyboardFocusRequest,
                                        isFocused: $isKeyboardFocused,
                                        onInsertText: sendText,
                                        onDeleteBackward: deleteBackward,
                                        onReturn: sendReturn,
                                        onPasteText: session.supportsClipboardPaste ? session.pasteText : nil,
                                        accessoryContent: keyboardAccessory)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .task(id: presentation) {
            // External-display mode keeps its existing automatic keyboard entry.
            // A folded pane's parent owns focus across fold and keyboard changes.
            guard presentation == .externalDisplay else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
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

    private var keyboardAccessory: AnyView? {
        guard presentation == .folded else { return nil }
        return AnyView(SessionShortcutStrip(session: session,
                                            heldModifierKeys: $heldModifierKeys,
                                            onSend: requestKeyboardFocus))
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

    private func trackpad(compact: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(.white.opacity(0.08))
                .stroke(.white.opacity(0.18), lineWidth: 1)

            RemoteDesktopView(session: session,
                              selectedFramebufferFrame: session.selectedDisplayFrame,
                              zoomScale: $trackpadZoomScale,
                              followsCursor: false,
                              acceptsHardwareKeyboardInput: presentation == .folded
                                  && allowsHardwareKeyboardInput && !isKeyboardFocused,
                              showsFramebuffer: false,
                              showsCursorOverlay: false,
                              allowsZoom: presentation == .externalDisplay,
                              touchModeOverride: .trackpad)
                .clipShape(.rect(cornerRadius: 28))
        }
        .overlay {
            Group {
                if presentation == .externalDisplay {
                    ViewThatFits(in: .vertical) {
                        trackpadInstructions
                        Image(systemName: "hand.draw")
                            .font(.largeTitle)
                    }
                } else {
                    ViewThatFits(in: [.horizontal, .vertical]) {
                        if !compact {
                            trackpadInstructions
                        }
                        Label("Trackpad", systemImage: "hand.draw")
                            .font(.subheadline)
                        Image(systemName: "hand.draw")
                            .font(.title3)
                        Color.clear
                    }
                }
            }
            .padding(presentation == .folded ? 8 : 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote trackpad")
        .accessibilityHint("Move with one finger, scroll with two fingers, or tap with two fingers to right-click.")
    }

    private var trackpadInstructions: some View {
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
