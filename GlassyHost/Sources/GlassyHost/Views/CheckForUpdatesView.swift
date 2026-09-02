import SwiftUI

struct CheckForUpdatesView: View {
    let updater: HostUpdateController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        .help(updater.statusMessage)
    }
}
