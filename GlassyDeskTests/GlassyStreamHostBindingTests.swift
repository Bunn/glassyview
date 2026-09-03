import Foundation
import Testing
@testable import GlassyDesk

struct GlassyStreamHostBindingTests {
    private let identifier = Data(repeating: 0x42, count: 16)
    private let lan = GlassyStreamDirectAddress(host: "192.168.1.20", port: 51_515)
    private let tailscale = GlassyStreamDirectAddress(host: "100.80.12.34", port: 51_515)
    private let wireguard = GlassyStreamDirectAddress(host: "10.20.0.2", port: 51_515)

    @Test
    func remoteQRPairingSavesWinningVPNAndKeepsLANForLater() throws {
        let result = try GlassyStreamHostBinding.applying(
            authentication(connectedAddress: tailscale),
            to: SavedMachine(name: "", host: "", username: "", connectionMode: .glassyStream),
            via: candidate
        )
        #expect(result.host == tailscale.host)
        #expect(result.port == tailscale.port)
        #expect(result.glassyHostAddresses == [tailscale, lan, wireguard].map(\.displayValue))
        #expect(result.glassyHostIdentifier == identifier.base64EncodedString())
    }

    @Test
    func returningToLANPromotesWorkingRouteAndKeepsVPNRoutes() throws {
        var machine = SavedMachine(name: "Studio", host: tailscale.host, username: "",
                                   connectionMode: .glassyStream,
                                   glassyHostIdentifier: identifier.base64EncodedString())
        machine.glassyHostAddresses = [tailscale, wireguard].map(\.displayValue)
        let result = try GlassyStreamHostBinding.applying(
            authentication(connectedAddress: lan), to: machine, via: candidate
        )
        #expect(result.host == lan.host)
        #expect(result.glassyHostAddresses == [lan, tailscale, wireguard].map(\.displayValue))
    }

    @Test
    func refusesToReplaceSavedIdentityWithDifferentMac() {
        let machine = SavedMachine(name: "Studio", host: lan.host, username: "",
                                   connectionMode: .glassyStream,
                                   glassyHostIdentifier: Data(repeating: 7, count: 16).base64EncodedString())
        #expect(throws: GlassyStreamSessionError.self) {
            try GlassyStreamHostBinding.applying(
                authentication(connectedAddress: tailscale), to: machine, via: candidate
            )
        }
    }

    @Test
    func refusesAHostThatDoesNotMatchTheScannedInvitation() {
        let unexpected = GlassyStreamAuthentication(
            hostIdentifier: Data(repeating: 7, count: 16), hostName: "Other Mac",
            maximumMediaPayloadLength: 1_024, resumedSession: false,
            supportsStreamQuality: true, supportsCursorPositionUpdates: true,
            connectedAddress: lan
        )
        #expect(throws: GlassyStreamSessionError.self) {
            try GlassyStreamHostBinding.applying(
                unexpected, to: SavedMachine(name: "", host: "", username: ""), via: candidate
            )
        }
    }

    @Test
    func doesNotCarryUnpinnedStaleAddressesIntoNewPairing() throws {
        var machine = SavedMachine(name: "", host: "", username: "")
        machine.glassyHostAddresses = ["old-mac.local:51515"]
        let result = try GlassyStreamHostBinding.applying(
            authentication(connectedAddress: tailscale), to: machine, via: candidate
        )
        #expect(!result.glassyHostAddresses.contains("old-mac.local:51515"))
    }

    private var candidate: GlassyStreamEndpointCandidate {
        GlassyStreamEndpointCandidate(
            id: "qr", name: "Studio", detail: lan.displayValue, source: .direct,
            endpoint: lan.endpoint, directAddress: lan,
            expectedHostIdentifier: identifier, alternateAddresses: [tailscale, wireguard]
        )
    }

    private func authentication(connectedAddress: GlassyStreamDirectAddress) -> GlassyStreamAuthentication {
        GlassyStreamAuthentication(
            hostIdentifier: identifier, hostName: "Studio", maximumMediaPayloadLength: 1_024,
            resumedSession: false, supportsStreamQuality: true,
            supportsCursorPositionUpdates: true, connectedAddress: connectedAddress
        )
    }
}
