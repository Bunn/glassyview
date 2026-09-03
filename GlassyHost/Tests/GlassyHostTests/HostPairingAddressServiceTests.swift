import Darwin
import Foundation
import Testing
@testable import GlassyHost

private let activeInterfaceFlags = UInt32(IFF_UP | IFF_RUNNING)

@Test("Pairing candidates retain Tailscale, WireGuard, LAN and DNS when IPv6 addresses are numerous")
func pairingAddressSelectionPreservesNetworkCoverage() {
    var interfaces = [
        pairingInterface("utun4", "100.102.22.80"),
        pairingInterface("utun4", "fd7a:115c:a1e0:ab12:1234:5678:abcd:ef01"),
        pairingInterface("utun2", "10.8.0.2"),
        pairingInterface("utun2", "fd12:3456::2"),
        pairingInterface("en0", "192.168.1.42")
    ]
    interfaces += (1...12).map { pairingInterface("en0", "2001:db8:1234:5678::\($0)") }
    let selected = HostPairingAddressPolicy.select(from: interfaces, localHostName: "Studio-Mac")
    #expect(selected.count == 8)
    #expect(selected.first == "100.102.22.80")
    #expect(selected.contains("192.168.1.42"))
    #expect(selected.contains("10.8.0.2"))
    #expect(selected.contains("fd7a:115c:a1e0:ab12:1234:5678:abcd:ef01"))
    #expect(selected.contains("fd12:3456::2"))
    #expect(selected.last == "studio-mac.local")
}

@Test("Pairing excludes down interfaces and addresses that cannot identify this Mac to another device")
func pairingAddressSelectionRejectsUnusableAddresses() {
    let rejected = [
        "0.0.0.0", "0.12.34.56", "127.0.0.1", "169.254.1.1", "224.0.0.1", "255.255.255.255",
        "::", "::1", "ff02::1", "fe80::1234", "fe80::1234%en0", "::ffff:127.0.0.1"
    ]
    var interfaces = rejected.map { pairingInterface("en0", $0) }
    interfaces.append(HostPairingInterfaceAddress(interfaceName: "en1", address: "192.168.4.2", flags: 0))
    interfaces.append(HostPairingInterfaceAddress(interfaceName: "lo0", address: "10.0.0.1", flags: activeInterfaceFlags | UInt32(IFF_LOOPBACK)))
    #expect(HostPairingAddressPolicy.select(from: interfaces, localHostName: nil).isEmpty)
    for address in rejected { #expect(HostPairingHostAddress.normalized(address) == nil) }
}

@Test("Pairing canonicalizes duplicate IPv6 endpoints and keeps Bonjour as a fallback")
func pairingAddressSelectionCanonicalizesDuplicates() {
    let interfaces = [pairingInterface("utun4", "fd12:0:0:0:0:0:0:42"), pairingInterface("utun5", "FD12::42")]
    #expect(HostPairingAddressPolicy.select(from: interfaces, localHostName: "Studio") == ["fd12::42", "studio.local"])
    #expect(HostPairingAddressPolicy.select(from: [], localHostName: "Studio") == ["studio.local"])
    #expect(HostPairingAddressPolicy.select(from: [], localHostName: nil).isEmpty)
}

@Test("Pairing addresses refresh when a split-tunnel VPN appears and disappears")
func pairingAddressRefreshObservesVPNChanges() async throws {
    let local = ["192.168.1.42", "studio.local"]
    let vpn = ["100.102.22.80", "192.168.1.42", "fd7a:115c:a1e0::42", "studio.local"]
    let source = PairingAddressSnapshots([local, vpn, local])
    let service = HostPairingAddressService(snapshotProvider: { source.current() }, refreshInterval: .milliseconds(20))
    let (updates, continuation) = AsyncStream<[String]>.makeStream()
    service.start { addresses in
        continuation.yield(addresses)
        source.advance()
    }
    let observed = try await withThrowingTaskGroup(of: [[String]].self) { group in
        group.addTask {
            var observed: [[String]] = []
            for await value in updates {
                observed.append(value)
                if observed.count == 3 { return observed }
            }
            return observed
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw PairingAddressRefreshTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next() ?? []
    }
    withExtendedLifetime(service) { #expect(observed == [local, vpn, local]) }
    continuation.finish()
}

private func pairingInterface(_ name: String, _ address: String) -> HostPairingInterfaceAddress {
    HostPairingInterfaceAddress(interfaceName: name, address: address, flags: activeInterfaceFlags)
}

private struct PairingAddressRefreshTimeout: Error {}

private final class PairingAddressSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[String]]
    init(_ snapshots: [[String]]) { self.snapshots = snapshots }
    func current() -> [String] { lock.withLock { snapshots[0] } }
    func advance() { lock.withLock { if snapshots.count > 1 { snapshots.removeFirst() } } }
}
