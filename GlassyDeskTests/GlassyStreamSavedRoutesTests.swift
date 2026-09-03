import Foundation
import Network
import Testing
@testable import GlassyDesk

struct GlassyStreamSavedRoutesTests {
    private let identifier = Data(repeating: 7, count: 16)

    @Test
    func pairedMacRestoresDistinctAlternateAddressesAndMatchingBonjourOnly() {
        var machine = makeMachine()
        machine.glassyHostAddresses = ["STUDIO-MAC.local.:51515", "100.64.0.2:51515", "192.168.1.24:51515", "bad/path"]
        let matching = discoveredHost(name: "Studio Mac")
        let unrelated = discoveredHost(name: "Other Mac")
        let candidates = GlassyStreamEndpoint.candidates(for: machine, discoveredHosts: [unrelated, matching])

        #expect(candidates.compactMap(\.directAddress).map(\.host) == ["Studio-Mac.local", "100.64.0.2", "192.168.1.24"])
        #expect(candidates.filter { $0.source == .bonjour }.map(\.name) == ["Studio Mac"])
        #expect(candidates.allSatisfy { $0.expectedHostIdentifier == identifier })
        #expect(candidates.first?.allDirectAddresses.count == 3)
    }

    @Test
    func savedAlternativesCannotRedirectAnUnpairedMac() {
        var machine = makeMachine()
        machine.glassyHostIdentifier = nil
        machine.glassyHostAddresses = ["100.64.0.2:51515"]
        let candidates = GlassyStreamEndpoint.candidates(for: machine, discoveredHosts: [discoveredHost(name: "Other Mac")])
        #expect(candidates.count == 1)
        #expect(candidates.first?.directAddress?.host == machine.host)
        #expect(candidates.first?.fallbackEndpoints.isEmpty == true)
        #expect(candidates.first?.expectedHostIdentifier == nil)
    }

    @Test
    func passwordPairingPromotesPinnedVPNRouteAndExcludesLANFallbacks() throws {
        let lan = GlassyStreamDirectAddress(host: "192.168.1.24", port: 51_515)
        let tailscale = GlassyStreamDirectAddress(host: "100.64.0.2", port: 51_515)
        let tailscaleIPv6 = GlassyStreamDirectAddress(host: "fd7a:115c:a1e0::2", port: 51_515)
        let candidate = GlassyStreamEndpointCandidate(
            id: "saved", name: "Studio", detail: lan.displayValue, source: .direct,
            endpoint: lan.endpoint, directAddress: lan, expectedHostIdentifier: identifier,
            alternateAddresses: [tailscale, GlassyStreamDirectAddress(host: "192.168.2.24", port: 51_515), tailscaleIPv6]
        )
        let passwordRoute = try #require(candidate.passwordPairingCandidate)
        #expect(passwordRoute.directAddress == tailscale)
        #expect(passwordRoute.alternateAddresses == [tailscaleIPv6])
        #expect(passwordRoute.expectedHostIdentifier == identifier)
        #expect(candidate.directAddress == lan)
    }

    @Test
    func passwordPairingCannotPromoteUnpinnedVPNAlternative() {
        let lan = GlassyStreamDirectAddress(host: "192.168.1.24", port: 51_515)
        let candidate = GlassyStreamEndpointCandidate(
            id: "manual", name: "Studio", detail: lan.displayValue, source: .direct,
            endpoint: lan.endpoint, directAddress: lan,
            alternateAddresses: [GlassyStreamDirectAddress(host: "100.64.0.2", port: 51_515)]
        )
        #expect(candidate.passwordPairingCandidate == nil)
    }

    @Test
    func explicitUnpinnedTailscaleRouteRemainsAvailableWithoutImplicitFallbacks() throws {
        let tailscale = GlassyStreamDirectAddress(host: "100.64.0.2", port: 51_515)
        let candidate = GlassyStreamEndpointCandidate(
            id: "manual", name: "Studio", detail: tailscale.displayValue, source: .direct,
            endpoint: tailscale.endpoint, directAddress: tailscale,
            alternateAddresses: [GlassyStreamDirectAddress(host: "100.64.0.3", port: 51_515)]
        )
        let passwordRoute = try #require(candidate.passwordPairingCandidate)
        #expect(passwordRoute.directAddress == tailscale)
        #expect(passwordRoute.fallbackEndpoints.isEmpty)
    }

    @Test
    func boundsSavedRouteCandidatesAndSupportsAlternateOnlyLegacyRecord() {
        var machine = makeMachine()
        machine.glassyHostAddresses = (1...20).map { "100.64.0.\($0):51515" }
        let candidates = GlassyStreamEndpoint.candidates(for: machine, discoveredHosts: [])
        #expect(candidates.count == 8)
        #expect(candidates.allSatisfy { $0.allDirectAddresses.count <= 8 })

        machine.host = ""
        let alternateOnly = GlassyStreamEndpoint.candidates(for: machine, discoveredHosts: [])
        #expect(alternateOnly.count == 8)
        #expect(alternateOnly.first?.directAddress?.host == "100.64.0.1")
    }

    @Test
    func savedMachineCodablePreservesRoutesAndReadsLegacyRecords() throws {
        var machine = makeMachine()
        machine.glassyHostAddresses = ["100.64.0.2:51515", "[fd7a:115c:a1e0::2]:51515"]
        let encoded = try JSONEncoder().encode(machine)
        #expect(try JSONDecoder().decode(SavedMachine.self, from: encoded) == machine)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "glassyHostAddresses")
        let decoded = try JSONDecoder().decode(SavedMachine.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.glassyHostAddresses.isEmpty)
        #expect(decoded.glassyHostIdentifier == machine.glassyHostIdentifier)
    }

    @Test @MainActor
    func swiftDataConvertersPreserveRoutesAndReadPreMigrationRecords() {
        var machine = makeMachine()
        machine.glassyHostAddresses = ["100.64.0.2:51515", "Studio-Mac.local:51515"]
        let record = SavedMachineRecord(machine: machine, sortOrder: 0)
        #expect(record.savedMachine.glassyHostAddresses == machine.glassyHostAddresses)
        machine.glassyHostAddresses = ["192.168.1.24:51515"]
        record.update(from: machine)
        #expect(record.savedMachine.glassyHostAddresses == machine.glassyHostAddresses)
        record.glassyHostAddressesData = nil
        #expect(record.savedMachine.glassyHostAddresses.isEmpty)
        record.glassyHostAddressesData = Data("invalid".utf8)
        #expect(record.savedMachine.glassyHostAddresses.isEmpty)
    }

    private func makeMachine() -> SavedMachine {
        SavedMachine(name: "Studio Mac", host: "Studio-Mac.local", port: 51_515, username: "",
                     connectionMode: .glassyStream, glassyHostIdentifier: identifier.base64EncodedString(),
                     glassyHostName: "Studio Mac")
    }

    private func discoveredHost(name: String) -> DiscoveredGlassyHost {
        DiscoveredGlassyHost(id: name, name: name,
                            endpoint: .service(name: name, type: "_glassydesk._tcp", domain: "local.", interface: nil))
    }
}
