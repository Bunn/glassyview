import Foundation
import Testing
@testable import GlassyDesk

struct GlassyHostPairingInvitationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let valid = "glassydesk://pair?v=1&host=Studio-Mac.local&port=51515&name=Studio%20Mac&code=ABCD2345EFGH&expires=1800000060"

    @Test
    func readsHostPayloadWithoutChangingAuthenticationCode() throws {
        let invitation = try GlassyHostPairingInvitation(scannedValue: valid, now: now)

        #expect(invitation.host == "Studio-Mac.local")
        #expect(invitation.port == 51_515)
        #expect(invitation.name == "Studio Mac")
        #expect(invitation.code.rawValue == "ABCD2345EFGH")
        #expect(invitation.expiresAt.timeIntervalSince(now) == 60)
        #expect(invitation.candidate.directAddress?.host == invitation.host)
        #expect(invitation.candidate.directAddress?.port == invitation.port)
    }

    @Test(arguments: ["192.168.1.24", "100.64.0.2", "fd7a:115c:a1e0::2", "my-mac.tail123.ts.net"])
    func acceptsSupportedNetworkAddresses(host: String) throws {
        let value = valid.replacingOccurrences(of: "Studio-Mac.local", with: host)
        let invitation = try GlassyHostPairingInvitation(scannedValue: value, now: now)
        #expect(invitation.host == host)
    }

    @Test(arguments: [
        "v=2", "host=mac.local&host=other.local", "host=", "host=mac.local:51515",
        "host=bad%2Fpath", "host=bad%40address", "host=-invalid.local", "host=bad..local",
        "port=0", "port=65536", "port=-1", "port=5.5", "port=%2B51515",
        "name=", "name=%0AHidden", "name=%E2%80%AEHidden", "name=Trailing%20",
        "code=abcd2345efgh", "code=ABCD-2345-EFGH", "code=ABCD2345EFG0",
        "expires=1800000601", "expires=nan", "expires=1800000060.0"
    ])
    func rejectsMalformedFields(replacement: String) {
        let key = String(replacement.prefix { $0 != "=" })
        let items = valid.split(separator: "?")[1].split(separator: "&")
        let query = items.map { $0.hasPrefix(key + "=") ? replacement : String($0) }
            .joined(separator: "&")

        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: "glassydesk://pair?" + query, now: now)
        }
    }

    @Test(arguments: [
        "https://pair?", "glassydesk://other?", "GLASSYDESK://pair?",
        "glassydesk://pair/?", "glassydesk://user@pair?", "glassydesk://pair:80?"
    ])
    func rejectsOtherRoutes(prefix: String) {
        let value = valid.replacingOccurrences(of: "glassydesk://pair?", with: prefix)
        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: value, now: now)
        }
    }

    @Test(arguments: ["&extra=value", "&v=1", "#fragment", "&host=other.local"])
    func rejectsAmbiguousOrExtraContent(suffix: String) {
        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: valid + suffix, now: now)
        }
    }

    @Test
    func rejectsExpiredCodeAtTheExactExpirationBoundary() {
        #expect(throws: GlassyHostPairingInvitation.ValidationError.expired) {
            try GlassyHostPairingInvitation(scannedValue: valid, now: now.addingTimeInterval(60))
        }
    }

    @Test
    func rejectsOversizedAndMalformedEncodedInput() {
        for value in [valid + String(repeating: "x", count: 2_048),
                      valid.replacingOccurrences(of: "Studio%20Mac", with: "Bad%ZZ"),
                      valid.replacingOccurrences(of: "Studio-Mac.local", with: String(repeating: "a", count: 64) + ".local"),
                      valid.replacingOccurrences(of: "Studio%20Mac", with: String(repeating: "a", count: 256))] {
            #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
                try GlassyHostPairingInvitation(scannedValue: value, now: now)
            }
        }
    }
}
