import SwiftUI

struct GlassyStreamDetectionBadge: View {
    var title = "Glassy Stream Detected"

    var body: some View {
        Label(title, systemImage: "bolt.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
