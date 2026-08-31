import SwiftUI

struct ExternalRemoteDisplayView: View {
    @ObservedObject var session: VNCSession
    let sessionTitle: String

    @State private var zoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch session.status {
            case .connected:
                remoteDesktop
            case .reconnecting(let reconnectState):
                SessionRemoteContent(session: session,
                                     reconnectState: reconnectState,
                                     zoomScale: $zoomScale,
                                     followsCursor: false,
                                     acceptsHardwareKeyboardInput: false,
                                     acceptsPointerInput: false)
            case .idle, .connecting:
                statusView(title: "Connecting to \(sessionTitle)", showsProgress: true)
            case .disconnected:
                statusView(title: "Disconnected from \(sessionTitle)", showsProgress: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var remoteDesktop: some View {
        RemoteDesktopView(session: session,
                          selectedFramebufferFrame: session.selectedDisplayFrame,
                          zoomScale: $zoomScale,
                          followsCursor: false,
                          acceptsHardwareKeyboardInput: false,
                          acceptsPointerInput: false,
                          // The iPhone always controls this surface as a trackpad.
                          touchModeOverride: .trackpad)
            .id(session.displaySelection.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }

    private func statusView(title: String, showsProgress: Bool) -> some View {
        VStack(spacing: 16) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            }

            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
