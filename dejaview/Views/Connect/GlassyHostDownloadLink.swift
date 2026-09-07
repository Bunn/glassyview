import SwiftUI

struct GlassyHostDownloadLink: View {
    private let destination = GlassyDeskLinks.macSetup

    var body: some View {
        Link(destination: destination) {
            Label("Get Glassy Desk for Mac", systemImage: "arrow.down.circle")
        }
        .accessibilityHint("Opens the Mac download and setup guide on the Glassy Desk website.")
        .accessibilityIdentifier("connection.glassy-host.download")
    }
}
