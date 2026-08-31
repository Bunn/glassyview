import SwiftUI

struct SessionRemoteContent<Session: RemoteSessionControlling>: View {
    let session: Session
    let reconnectState: RemoteReconnectState?
    @Binding var zoomScale: CGFloat
    let followsCursor: Bool
    var pansViewportWithTwoFingers = false
    var showsTrackpadCursorDot = false
    let acceptsHardwareKeyboardInput: Bool
    var acceptsPointerInput: Bool = true
    var glassyStream: GlassyStreamSessionController?

    var body: some View {
        ZStack {
            if let glassyStream {
                RemoteDesktopView(session: session,
                                  selectedFramebufferFrame: nil,
                                  zoomScale: $zoomScale,
                                  followsCursor: followsCursor,
                                  pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                  acceptsHardwareKeyboardInput: acceptsHardwareKeyboardInput,
                                  acceptsPointerInput: acceptsPointerInput,
                                  showsFramebuffer: false,
                                  showsTrackpadCursorDot: showsTrackpadCursorDot,
                                  allowsZoom: true,
                                  glassyStreamRenderer: glassyStream.renderer)
                    .ignoresSafeArea(.container)

                if reconnectState == nil {
                    GlassyStreamStatusOverlay(controller: glassyStream)
                        .allowsHitTesting(false)
                }
            } else {
                RemoteDesktopView(session: session,
                                  selectedFramebufferFrame: session.selectedDisplayFrame,
                                  zoomScale: $zoomScale,
                                  followsCursor: followsCursor,
                                  pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                  acceptsHardwareKeyboardInput: acceptsHardwareKeyboardInput,
                                  acceptsPointerInput: acceptsPointerInput,
                                  showsTrackpadCursorDot: showsTrackpadCursorDot)
                    .id(session.displaySelection.id)
                    .ignoresSafeArea(.container)
            }

            if let reconnectState {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                SessionReconnectOverlay(state: reconnectState,
                                        retryNow: session.retryConnect,
                                        cancel: session.cancelReconnect)
            }
        }
    }
}

private struct GlassyStreamStatusOverlay: View {
    let controller: GlassyStreamSessionController

    var body: some View {
        if let failureMessage {
            VStack(spacing: 12) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                Text("Glassy Stream Stopped")
                    .font(.headline)

                Text(failureMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(28)
        } else if isWaitingForVideo {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for Glassy Stream video…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var failureMessage: String? {
        guard controller.state == .failed else { return nil }
        return controller.error?.localizedDescription
            ?? "The fast video connection ended. Close this session and reconnect."
    }

    private var isWaitingForVideo: Bool {
        guard controller.state != .failed else { return false }

        return switch controller.renderer.state {
        case .waitingForConfiguration, .waitingForKeyFrame:
            true
        case .rendering, .failed:
            false
        }
    }
}
