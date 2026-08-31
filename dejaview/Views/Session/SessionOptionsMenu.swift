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
    @Binding var zoomScale: CGFloat
    @Binding var followsCursor: Bool
    @Binding var pansViewportWithTwoFingers: Bool
    var usesGlassyStream = false
    var includesDisplayPicker = false
    var includesResetZoom = false
    var includesZoomModes = false

    var body: some View {
        Menu {
            if includesDisplayPicker,
               !usesGlassyStream,
               session.displayOptions.count > 1 {
                Picker("Display", selection: displayBinding) {
                    ForEach(session.displayOptions) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option.selection)
                    }
                }
                .pickerStyle(.inline)
            }

            if includesResetZoom {
                Button("Reset Zoom", systemImage: "arrow.counterclockwise") {
                    zoomScale = 1
                }
                .disabled(zoomScale == 1)
            }

            if includesZoomModes {
                Toggle("Keep Cursor Visible", systemImage: "scope",
                       isOn: $followsCursor)
                Toggle("Pan View with Two Fingers", systemImage: "hand.draw",
                       isOn: $pansViewportWithTwoFingers)
            }

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
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityHint("Shows available session controls.")
    }

    private var displayBinding: Binding<RemoteDisplaySelection> {
        Binding {
            session.displaySelection
        } set: { selection in
            session.setDisplaySelection(selection)
        }
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
