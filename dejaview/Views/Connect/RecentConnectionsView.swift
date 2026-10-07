import SwiftUI

struct RecentConnectionsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entries: [ConnectionHistoryEntry]
    let availableWidth: CGFloat
    let isSearching: Bool
    let canReconnectDirectly: (ConnectionHistoryEntry) -> Bool
    let connect: (ConnectionHistoryEntry) -> Void
    let delete: (ConnectionHistoryEntry) -> Void

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: min(320, max(1, availableWidth))), spacing: 16, alignment: .top)]
    }

    var body: some View {
        if entries.isEmpty {
            if isSearching {
                ContentUnavailableView.search
            } else {
                ContentUnavailableView("No Recent Sessions",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text("Sessions appear here after a connection succeeds."))
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .glassPanel(cornerRadius: 28)
            }
        } else {
            GlassEffectContainer(spacing: 16) {
                LazyVGrid(columns: columns,
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(entries) { entry in
                        RecentConnectionTile(entry: entry,
                                             canReconnectDirectly: canReconnectDirectly(entry)) {
                            connect(entry)
                        } delete: {
                            delete(entry)
                        }
                    }
                }
            }
        }
    }
}
