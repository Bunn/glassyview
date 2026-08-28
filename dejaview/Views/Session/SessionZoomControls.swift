import SwiftUI

struct SessionZoomControls: View {
    @Binding var zoomScale: CGFloat
    @Binding var followsCursor: Bool

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

            Button(action: toggleFollowCursor) {
                Image(systemName: "scope")
                    .font(.body.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(followsCursor ? .green : .white)
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep Cursor Visible")
            .accessibilityValue(followsCursor ? "On" : "Off")
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

    private func zoomIn() {
        zoomScale = min(zoomScale + zoomStep, maximumZoomScale)
    }

    private func zoomOut() {
        zoomScale = max(zoomScale - zoomStep, minimumZoomScale)
    }

    private func resetZoom() {
        zoomScale = minimumZoomScale
    }

    private func toggleFollowCursor() {
        followsCursor.toggle()
    }
}
