import Foundation
import Testing
@testable import GlassyHost

@Test("A delayed optional password load cannot overwrite a local credential action")
func delayedPairingPasswordLoadRespectsLocalMutation() {
    let hostIdentifier = Data(repeating: 0x01, count: HostProtocol.identifierLength)
    var state = HostPairingPasswordLoadState()
    let pendingRead = state.begin(for: hostIdentifier)
    #expect(state.accepts(pendingRead, hostIdentifier: hostIdentifier))

    // Set, remove, and reset all invalidate pending reads before suspending.
    state.invalidate()
    #expect(!state.accepts(pendingRead, hostIdentifier: hostIdentifier))
    let currentRead = state.begin(for: hostIdentifier)
    #expect(state.accepts(currentRead, hostIdentifier: hostIdentifier))
    #expect(!state.accepts(pendingRead, hostIdentifier: hostIdentifier))
}

@Test("A password load for the old host identity cannot apply after key rotation")
func delayedPairingPasswordLoadRespectsHostIdentity() {
    let originalIdentifier = Data(repeating: 0x01, count: HostProtocol.identifierLength)
    let replacementIdentifier = Data(repeating: 0x02, count: HostProtocol.identifierLength)
    var state = HostPairingPasswordLoadState()
    let pendingRead = state.begin(for: originalIdentifier)
    #expect(!state.accepts(pendingRead, hostIdentifier: replacementIdentifier))
    #expect(!state.accepts(pendingRead, hostIdentifier: nil))
}
