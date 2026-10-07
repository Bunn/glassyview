import SwiftUI

struct SessionRemoteContent<Session: RemoteSessionControlling>: View {
    @Environment(\.remoteContentRespectsContainer) private var respectsContainer
    @Environment(\.remoteContentOverlayBottomInset) private var overlayBottomInset
    @Environment(\.remoteContentFittingSize) private var paneFittingSize
    @State private var fittingViewportSize: CGSize?
    let session: Session
    let reconnectState: RemoteReconnectState?
    @Binding var zoomScale: CGFloat
    let followsCursor: Bool
    var pansViewportWithTwoFingers = false
    var keyboardAvoidanceActive = false
    var showsTrackpadCursorDot = false
    let acceptsHardwareKeyboardInput: Bool
    var acceptsPointerInput: Bool = true
    var touchModeOverride: RemoteTouchMode?
    var glassyStream: GlassyStreamSessionController?

    var body: some View {
        ZStack {
            if let glassyStream {
                RemoteDesktopView(session: session,
                                  selectedFramebufferFrame: nil,
                                  zoomScale: $zoomScale,
                                  fittingViewportSize: paneFittingSize ?? fittingViewportSize,
                                  followsCursor: followsCursor,
                                  pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                  keyboardAvoidanceActive: keyboardAvoidanceActive,
                                  acceptsHardwareKeyboardInput: acceptsHardwareKeyboardInput,
                                  acceptsPointerInput: acceptsPointerInput,
                                  showsFramebuffer: false,
                                  showsTrackpadCursorDot: showsTrackpadCursorDot,
                                  allowsZoom: true,
                                  touchModeOverride: touchModeOverride,
                                  glassyStreamRenderer: glassyStream.renderer)
                    .ignoresSafeArea(.container, edges: ignoredContainerSafeAreaEdges)

                if reconnectState == nil {
                    GlassyStreamStatusOverlay(controller: glassyStream)
                }
            } else {
                RemoteDesktopView(session: session,
                                  selectedFramebufferFrame: session.selectedDisplayFrame,
                                  zoomScale: $zoomScale,
                                  fittingViewportSize: paneFittingSize ?? fittingViewportSize,
                                  followsCursor: followsCursor,
                                  pansViewportWithTwoFingers: pansViewportWithTwoFingers,
                                  keyboardAvoidanceActive: keyboardAvoidanceActive,
                                  acceptsHardwareKeyboardInput: acceptsHardwareKeyboardInput,
                                  acceptsPointerInput: acceptsPointerInput,
                                  showsTrackpadCursorDot: showsTrackpadCursorDot,
                                  touchModeOverride: touchModeOverride)
                    .id(session.displaySelection.id)
                    .ignoresSafeArea(.container, edges: ignoredContainerSafeAreaEdges)
            }

            if let reconnectState {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                SessionStatusContainer {
                    SessionReconnectOverlay(state: reconnectState,
                                            retryNow: session.retryConnect,
                                            cancel: session.cancelReconnect)
                }
            }
        }
        .background {
            // Measure this pane without the keyboard, never the whole window. The
            // rendered viewport still avoids the keyboard and retains its zoom.
            GeometryReader { geometry in
                // A protected pane must retain its hardware boundaries. Restore
                // only our own input overlay inset when measuring its full fit;
                // the unconstrained measurement already ignores that safe area.
                let fittingSize = CGSize(width: geometry.size.width,
                                         height: geometry.size.height + (respectsContainer ? overlayBottomInset : 0))
                Color.clear
                    .onChange(of: fittingSize, initial: true) { _, size in
                        fittingViewportSize = size
                    }
            }
            .ignoresSafeArea(.container, edges: respectsContainer ? [] : .all)
            .ignoresSafeArea(.keyboard)
        }
    }

    private var ignoredContainerSafeAreaEdges: Edge.Set {
        if respectsContainer { return [] }
        return keyboardAvoidanceActive ? [.top, .leading, .trailing] : .all
    }
}

private struct GlassyStreamStatusOverlay: View {
    let controller: GlassyStreamSessionController

    var body: some View {
        if let failureMessage {
            SessionStatusContainer {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)

                    Text(controller.error == nil && controller.hostStatus?.message != nil
                         ? String(localized: "Check Your Mac") : String(localized: "Connection Stopped"))
                        .font(.headline)

                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(22)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(12)
            }
        } else if isWaitingForVideo {
            SessionStatusContainer {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Waiting for your Mac…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        } else if let message = controller.hostStatus?.message {
            VStack {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    private var failureMessage: String? {
        if let status = controller.hostStatus,
           status.state != .streaming, status.state != .starting {
            return status.message
        }
        guard controller.state == .failed else { return nil }
        return controller.error?.localizedDescription
            ?? "The fast video connection ended. Close this session and reconnect."
    }

    private var isWaitingForVideo: Bool {
        // Recovery can keep the last decoded image visible while a fresh
        // keyframe arrives. Show progress only when there is no image yet.
        guard controller.state != .failed, !controller.renderer.isDisplayingVideo else { return false }

        return switch controller.renderer.state {
        case .waitingForConfiguration, .waitingForKeyFrame:
            true
        case .rendering, .failed:
            false
        }
    }
}
