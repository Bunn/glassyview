import Foundation
import Testing
@testable import GlassyDesk

struct WidgetMachineSelectionResolverTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test
    func quickSelectionDefaultsOnlyWhenUnconfigured() {
        let machines = snapshots
        let missingID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

        #expect(WidgetMachineSelectionResolver().quickSelection(
            configuredID: nil,
            machines: machines
        )?.id == firstID)
        #expect(WidgetMachineSelectionResolver().quickSelection(
            configuredID: missingID,
            machines: machines
        ) == nil)
    }

    @Test
    func multipleSelectionPreservesOrderDeduplicatesDropsStaleAndLimits() {
        let missingID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let result = WidgetMachineSelectionResolver().multipleSelection(
            configuredIDs: [thirdID, missingID, firstID, thirdID, secondID],
            machines: snapshots,
            limit: 2
        )

        #expect(result.map(\.id) == [thirdID, firstID])
    }

    @Test
    func multipleSelectionDefaultsToSavedOrderWhenUnconfigured() {
        let result = WidgetMachineSelectionResolver().multipleSelection(
            configuredIDs: nil,
            machines: snapshots,
            limit: 2
        )

        #expect(result.map(\.id) == [firstID, secondID])
    }

    private var snapshots: [WidgetMachineSnapshot] {
        [firstID, secondID, thirdID].map {
            WidgetMachineSnapshot(
                id: $0,
                displayName: "Mac \($0.uuidString.suffix(1))",
                connectionKind: .vnc,
                lastConnectedAt: nil,
                reachability: .unknown,
                reachabilityCheckedAt: nil
            )
        }
    }
}
