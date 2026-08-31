import SwiftUI

struct SessionZoomControls: View {
    @Binding var zoomScale: CGFloat
    @Binding var followsCursor: Bool
    @Binding var pansViewportWithTwoFingers: Bool
    var showsResetZoom = true
    var showsZoomModes = true

    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 4
    private let zoomStep: CGFloat = 0.25

    private var zoomPercent: Int {
        Int((zoomScale * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 0) {
            zoomButton(String(localized: "Zoom Out"),
                       systemImage: "minus.magnifyingglass",
                       action: zoomOut)
                .disabled(zoomScale <= minimumZoomScale)

            Text("\(zoomPercent)%")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 50)
                .accessibilityLabel("Zoom \(zoomPercent) percent")

            zoomButton(String(localized: "Zoom In"),
                       systemImage: "plus.magnifyingglass",
                       action: zoomIn)
                .disabled(zoomScale >= maximumZoomScale)

            if showsResetZoom {
                zoomButton(String(localized: "Reset Zoom"),
                           systemImage: "arrow.counterclockwise",
                           action: resetZoom)
                    .disabled(zoomScale == minimumZoomScale)
            }

            if showsZoomModes {
                modeToggle(String(localized: "Keep Cursor Visible"),
                           systemImage: "scope",
                           isOn: $followsCursor,
                           hint: followsCursor
                               ? String(localized: "Moves the zoomed view when the cursor approaches an edge.")
                               : String(localized: "Leaves the zoomed view fixed as the cursor moves."))

                modeToggle(String(localized: "Pan View with Two Fingers"),
                           systemImage: "hand.draw",
                           isOn: $pansViewportWithTwoFingers,
                           hint: pansViewportWithTwoFingers
                               ? String(localized: "Two-finger swipes move the zoomed view.")
                               : String(localized: "Two-finger swipes scroll the remote Mac."))
            }
        }
    }

    private func zoomButton(_ title: String,
                            systemImage: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    private func modeToggle(_ title: String,
                            systemImage: String,
                            isOn: Binding<Bool>,
                            hint: String) -> some View {
        Toggle(isOn: isOn) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isOn.wrappedValue ? .green : .white)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(isOn.wrappedValue ? .white.opacity(0.18) : .clear)
                }
                .overlay {
                    if isOn.wrappedValue {
                        Circle()
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            isOn.wrappedValue ? String(localized: "On") : String(localized: "Off")
        )
        .accessibilityHint(hint)
        .help(Text(verbatim: hint))
    }

    private func zoomIn() {
        zoomScale = min(zoomScale + zoomStep, maximumZoomScale)
    }

    private func zoomOut() {
        zoomScale = max(zoomScale - zoomStep, minimumZoomScale)
    }

    private func resetZoom() {
        zoomScale = minimumZoomScale
    }

}
