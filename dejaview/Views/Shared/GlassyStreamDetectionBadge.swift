import SwiftUI

struct GlassyStreamDetectionBadge: View {
    var title: LocalizedStringResource = "Glassy Stream Detected"

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "bolt.fill")
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
