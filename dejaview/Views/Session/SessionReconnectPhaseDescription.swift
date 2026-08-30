import SwiftUI

struct SessionReconnectPhaseDescription: View {
    let phase: RemoteReconnectPhase

    var body: some View {
        switch phase {
        case .waitingForForeground:
            Text("The stream will resume when Glassy Desk is active again.")
        case .waitingForNetwork:
            Text("Waiting for the network to become available.")
        case .waiting(let retryDate):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(retryDescription(at: context.date, retryDate: retryDate))
            }
        case .connecting:
            Text("Contacting the remote computer.")
        }
    }

    private func retryDescription(at date: Date, retryDate: Date) -> String {
        let remainingSeconds = max(1, Int(retryDate.timeIntervalSince(date).rounded(.up)))
        if remainingSeconds == 1 {
            return String(localized: "Trying again in \(remainingSeconds) second.")
        }
        return String(localized: "Trying again in \(remainingSeconds) seconds.")
    }
}
