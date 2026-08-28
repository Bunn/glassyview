import SwiftUI

struct SessionZoomControls: View {
    @Binding var zoomScale: CGFloat
    @Binding var followsCursor: Bool
    @Binding var pansViewportWithTwoFingers: Bool

    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 4
    private let zoomStep: CGFloat = 0.25

    private var zoomPercent: Int {
        Int((zoomScale * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 2) {
            zoomButton("Zoom Out",
                       systemImage: "minus.magnifyingglass",
                       action: zoomOut)
                .disabled(zoomScale <= minimumZoomScale)

            Text("\(zoomPercent)%")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 58)
                .accessibilityLabel("Zoom \(zoomPercent) percent")

            zoomButton("Zoom In",
                       systemImage: "plus.magnifyingglass",
                       action: zoomIn)
                .disabled(zoomScale >= maximumZoomScale)

            Divider()
                .frame(height: 24)
                .overlay(.white.opacity(0.32))
                .padding(.horizontal, 4)

            zoomButton("Reset Zoom",
                       systemImage: "arrow.counterclockwise",
                       action: resetZoom)
                .disabled(zoomScale == minimumZoomScale)

            modeToggle("Keep Cursor Visible",
                       systemImage: "scope",
                       isOn: $followsCursor,
                       hint: followsCursor
                           ? "Moves the view only when the cursor reaches a visible edge."
                           : "Leaves the zoomed view fixed as the cursor moves.")

            modeToggle("Pan View with Two Fingers",
                       systemImage: "hand.draw",
                       isOn: $pansViewportWithTwoFingers,
                       hint: pansViewportWithTwoFingers
                           ? "Two-finger swipes move the zoomed view."
                           : "Two-finger swipes scroll the remote Mac.")
        }
        .padding(5)
        .liquidGlass(in: Capsule())
    }

    private func zoomButton(_ title: String,
                            systemImage: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 42, height: 42)
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
                .frame(width: 42, height: 42)
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
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
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
