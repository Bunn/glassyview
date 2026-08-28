import Foundation
import Testing
@testable import GlassyHost

@Test("A resumed viewer atomically replaces its stale connection")
func resumedViewerReplacesStaleConnection() {
    var registry = HostAuthenticatedClientRegistry()
    let clientIdentifier = Data(repeating: 0xA1, count: HostProtocol.identifierLength)
    let staleConnection = UUID()
    let resumedConnection = UUID()

    #expect(
        registry.activate(
            clientIdentifier: clientIdentifier,
            connectionIdentifier: staleConnection
        ) == nil
    )
    #expect(registry.activeConnectionCount == 1)

    let replacedConnection = registry.activate(
        clientIdentifier: clientIdentifier,
        connectionIdentifier: resumedConnection
    )

    #expect(replacedConnection == staleConnection)
    #expect(registry.activeConnectionCount == 1)
    #expect(
        registry.isActive(
            clientIdentifier: clientIdentifier,
            connectionIdentifier: resumedConnection
        )
    )
    #expect(
        !registry.isActive(
            clientIdentifier: clientIdentifier,
            connectionIdentifier: staleConnection
        )
    )

    let activeRequestedQualities = [
        (staleConnection, HostProtocol.StreamQuality.dataSaver),
        (resumedConnection, HostProtocol.StreamQuality.best),
    ].compactMap { connectionIdentifier, quality in
        registry.isActive(
            clientIdentifier: clientIdentifier,
            connectionIdentifier: connectionIdentifier
        ) ? quality : nil
    }
    #expect(
        HostStreamQualityArbitration.effectiveQuality(
            for: activeRequestedQualities
        ) == .best
    )
}

@Test("Late stale removal cannot evict a resumed viewer")
func lateStaleRemovalPreservesResumedViewer() {
    var registry = HostAuthenticatedClientRegistry()
    let clientIdentifier = Data(repeating: 0xB2, count: HostProtocol.identifierLength)
    let staleConnection = UUID()
    let resumedConnection = UUID()

    registry.activate(
        clientIdentifier: clientIdentifier,
        connectionIdentifier: staleConnection
    )
    registry.activate(
        clientIdentifier: clientIdentifier,
        connectionIdentifier: resumedConnection
    )

    let staleRemovalSucceeded = registry.deactivate(
        clientIdentifier: clientIdentifier,
        connectionIdentifier: staleConnection
    )
    #expect(!staleRemovalSucceeded)
    #expect(registry.activeConnectionCount == 1)
    #expect(
        registry.isActive(
            clientIdentifier: clientIdentifier,
            connectionIdentifier: resumedConnection
        )
    )

    let resumedRemovalSucceeded = registry.deactivate(
        clientIdentifier: clientIdentifier,
        connectionIdentifier: resumedConnection
    )
    #expect(resumedRemovalSucceeded)
    #expect(registry.activeConnectionCount == 0)
}

@Test("Different viewer identities remain independent")
func distinctViewerIdentitiesRemainActive() {
    var registry = HostAuthenticatedClientRegistry()
    let firstIdentifier = Data(repeating: 0xC3, count: HostProtocol.identifierLength)
    let secondIdentifier = Data(repeating: 0xD4, count: HostProtocol.identifierLength)
    let firstConnection = UUID()
    let secondConnection = UUID()

    registry.activate(
        clientIdentifier: firstIdentifier,
        connectionIdentifier: firstConnection
    )
    registry.activate(
        clientIdentifier: secondIdentifier,
        connectionIdentifier: secondConnection
    )

    #expect(registry.activeConnectionCount == 2)
    let firstRemovalSucceeded = registry.deactivate(
        clientIdentifier: firstIdentifier,
        connectionIdentifier: firstConnection
    )
    #expect(firstRemovalSucceeded)
    #expect(registry.activeConnectionCount == 1)
    #expect(
        registry.isActive(
            clientIdentifier: secondIdentifier,
            connectionIdentifier: secondConnection
        )
    )
}
