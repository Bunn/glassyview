import SwiftUI

struct GlassyHostDownloadLink: View {
    // Keep the existing release URL so downloads follow new Mac versions automatically.
    private let destination = URL(string: "https://github.com/Bunn/GlassyDesk-Host/releases/latest")!

    var body: some View {
        Link(destination: destination) {
            Label("Download Glassy Desk for Mac", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .accessibilityHint("Opens the latest Glassy Desk for Mac release. Install the download on your Mac.")
        .accessibilityIdentifier("connection.glassy-host.download")
    }
}
