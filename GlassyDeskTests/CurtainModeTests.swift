import Foundation
import Testing
@testable import GlassyDesk

@MainActor
struct CurtainModeTests {
    @Test
    func statusPayloadsAreExactAndRequestsAreFourBytes() throws {
        #expect(GlassyStreamWire.Capabilities.curtainMode.rawValue == 1 << 9)
        #expect(GlassyStreamWire.MessageKind.curtainRequest.rawValue == 0x25)
        #expect(GlassyStreamWire.MessageKind.curtainStatus.rawValue == 0x26)
        #expect(GlassyStreamWire.encodeCurtainRequest(enabled: true) == Data([1, 0, 0, 0]))
        #expect(GlassyStreamWire.encodeCurtainRequest(enabled: false) == Data([0, 0, 0, 0]))
        #expect(try GlassyStreamWire.decodeCurtainStatus(Data([3, 0, 0, 0])) == .init(state: .failed, blocksLocalInput: false))
        for invalid in [Data([4, 0, 0, 0]), Data([1, 2, 0, 0]), Data([1, 0, 0, 1]), Data([1, 0, 0])] {
            #expect(throws: GlassyStreamClientError.self) { try GlassyStreamWire.decodeCurtainStatus(invalid) }
        }
    }

    @Test
    func theMacsAnswerUpdatesTheRequestAndExplainsLimits() {
        let session = GlassyStreamRemoteSession()
        let report = session.controller.onCurtainStatusChanged
        session.setCurtainModeRequested(true)
        #expect(session.isCurtainModeRequested)
        #expect(session.curtainModeMessage == nil)

        report?(.init(state: .on, blocksLocalInput: true))
        #expect(session.curtainModeMessage == nil)

        report?(.init(state: .on, blocksLocalInput: false))
        #expect(session.curtainModeMessage?.contains("Accessibility") == true)
        session.clearCurtainModeMessage()

        report?(.init(state: .off, blocksLocalInput: false))
        #expect(session.isCurtainModeRequested, "The preference survives the Mac lifting the curtain")
        #expect(session.curtainModeMessage == "Curtain Mode ended on your Mac.")

        report?(.init(state: .unavailable, blocksLocalInput: false))
        #expect(!session.isCurtainModeRequested)
        #expect(session.curtainModeMessage?.contains("turned off on this Mac") == true)

        session.setCurtainModeRequested(true)
        report?(.init(state: .failed, blocksLocalInput: false))
        #expect(!session.isCurtainModeRequested)
    }

    @Test
    func perMachinePreferenceDefaultsOffAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SessionPreferences.self, from: Data(#"{"touchMode":"trackpad"}"#.utf8))
        #expect(!legacy.usesCurtainMode)
        var preferences = SessionPreferences.default
        preferences.usesCurtainMode = true
        let decoded = try JSONDecoder().decode(SessionPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.usesCurtainMode)

        let session = GlassyStreamRemoteSession()
        session.applyPreferences(preferences)
        #expect(session.isCurtainModeRequested)
    }
}
