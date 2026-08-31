import SwiftUI

/// Context menu for session options (bottom-right of the session).
struct SessionOptionsMenu<Session: RemoteSessionControlling>: View {
    // Safe to observe: framebuffer updates bypass objectWillChange (see
    // RemoteSessionControlling.framebufferUpdatePublisher), so this only re-renders on
    // actual state changes — which the menu checkmarks need to reflect.
    @ObservedObject var session: Session
    let sessionTitle: String
    @Bindable var externalDisplayCoordinator: ExternalDisplayCoordinator
    @Binding var showsTrackpadCursorDot: Bool
    var usesGlassyStream = false

    var body: some View {
        Menu {
            if session.supportedQualities.count > 1 {
                Picker("Requested Quality", selection: qualityBinding) {
                    ForEach(session.supportedQualities) { quality in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(quality.title)
                                Text(quality.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: quality.icon)
                        }
                        .tag(quality)
                    }
                }
                .pickerStyle(.inline)
            }

            Toggle("Trackpad Mode", systemImage: "cursorarrow.motionlines",
                   isOn: trackpadBinding)

            Toggle("Show Trackpad Dot", systemImage: "circle.fill",
                   isOn: $showsTrackpadCursorDot)
                .disabled(session.touchMode != .trackpad)

            if !usesGlassyStream {
                Picker("Frame Rate", selection: frameRateBinding) {
                    ForEach(RemoteFrameRate.allCases) { frameRate in
                        Label("\(frameRate.title) (\(frameRate.rawValue) FPS)",
                              systemImage: frameRate.systemImage)
                            .tag(frameRate)
                    }
                }
                .pickerStyle(.inline)
            }

            if !usesGlassyStream, let vncSession = session as? VNCSession {
                Section("External Display") {
                    ExternalDisplayControllerToggle(session: vncSession,
                                                    sessionTitle: sessionTitle,
                                                    coordinator: externalDisplayCoordinator)
                }
            }

#if DEBUG
            Section("Debug") {
                Button("Test Automatic Reconnect",
                       systemImage: "arrow.triangle.2.circlepath",
                       action: session.debugSimulateConnectionInterruption)
            }
#endif
        } label: {
            Label("Session Options", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(5)
        .liquidGlass(in: Circle())
        .accessibilityHint("Shows available session controls.")
    }

    private var qualityBinding: Binding<RemoteSessionQuality> {
        Binding {
            session.quality
        } set: { newQuality in
            session.setQuality(newQuality)
        }
    }

    // Idempotent setters: only toggle when the requested value actually
    // differs. SwiftUI may invoke a menu toggle's setter more than once per
    // tap, and a blind toggle() would cancel itself out.
    private var trackpadBinding: Binding<Bool> {
        Binding {
            session.touchMode == .trackpad
        } set: { isOn in
            if (session.touchMode == .trackpad) != isOn {
                session.toggleTouchMode()
            }
        }
    }

    private var frameRateBinding: Binding<RemoteFrameRate> {
        Binding {
            session.preferredFrameRate
        } set: { frameRate in
            session.setPreferredFrameRate(frameRate)
        }
    }
}
