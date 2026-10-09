import SwiftUI

struct ExternalDisplayRootView: View {
    @Bindable var coordinator: ExternalDisplayCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if coordinator.isControllerModeEnabled,
               let session = coordinator.activeSession {
                ExternalRemoteDisplayView(session: session,
                                          sessionTitle: coordinator.sessionTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppLockCoverInstaller(isInteractive: false))
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}
