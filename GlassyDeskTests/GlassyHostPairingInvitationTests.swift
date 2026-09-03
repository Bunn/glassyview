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
        #expect(invitation.expectedHostIdentifier == nil)
        #expect(invitation.addresses.count == 1)
        #expect(invitation.candidate.fallbackEndpoints.isEmpty)
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

    @Test
    func versionTwoCarriesIdentityAndMultipleRoutes() throws {
        let identifier = Data((0..<16).map(UInt8.init))
        let invitation = try GlassyHostPairingInvitation(
            scannedValue: versionTwo(identifier: identifier.base64EncodedString(),
                                     alternates: ["100.64.0.2", "192.168.1.24", "fd7a:115c:a1e0::2"]),
            now: now
        )
        #expect(invitation.expectedHostIdentifier == identifier)
        #expect(invitation.addresses.map(\.host) == ["Studio-Mac.local", "100.64.0.2", "192.168.1.24", "fd7a:115c:a1e0::2"])
        #expect(invitation.candidate.expectedHostIdentifier == identifier)
        #expect(invitation.candidate.allDirectAddresses == invitation.addresses)
        #expect(invitation.candidate.fallbackEndpoints.count == 3)
        #expect(invitation.matchesAddress(GlassyStreamDirectAddress(host: "100.64.0.2", port: 51_515)))
        #expect(invitation.matchesAddress(GlassyStreamDirectAddress(host: "STUDIO-MAC.local.", port: 51_515)))
        #expect(!invitation.matchesAddress(GlassyStreamDirectAddress(host: "other.local", port: 51_515)))
    }

    @Test(arguments: ["", "not-base64", "AAAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAAAB==", "AAAAAAAAAAAAAAAAAAAAAAA=", "AAAAAAAAAAAAAAAAAAAAAAA=="])
    func rejectsMalformedVersionTwoIdentity(identifier: String) {
        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: versionTwo(identifier: identifier), now: now)
        }
    }

    @Test(arguments: ["", "bad/path", "mac.local:51515", "tcp://mac.local", "fe80::1%en0", "[fd7a:115c:a1e0::2]", "STUDIO-MAC.local."])
    func rejectsInvalidOrDuplicateAlternateHosts(host: String) {
        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: versionTwo(alternates: [host]), now: now)
        }
    }

    @Test
    func boundsVersionTwoRoutesAndRejectsRepeatedEndpointSpellings() throws {
        let alternatives = (1...7).map { "100.64.0.\($0)" }
        #expect(try GlassyHostPairingInvitation(scannedValue: versionTwo(alternates: alternatives), now: now).addresses.count == 8)
        for hosts in [alternatives + ["100.64.0.8"],
                      ["100.64.0.2", "100.64.0.2"],
                      ["fd7a:115c:a1e0::2", "fd7a:115c:a1e0:0:0:0:0:2"]] {
            #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
                try GlassyHostPairingInvitation(scannedValue: versionTwo(alternates: hosts), now: now)
            }
        }
    }

    @Test(arguments: ["v", "host", "port", "name", "code", "expires", "id", "unknown"])
    func versionTwoRejectsDuplicateRequiredAndUnknownFields(key: String) {
        #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
            try GlassyHostPairingInvitation(scannedValue: versionTwo() + "&\(key)=extra", now: now)
        }
    }

    @Test
    func legacyPayloadCannotSmuggleVersionTwoFields() {
        for suffix in ["&alt=100.64.0.2", "&id=AAAAAAAAAAAAAAAAAAAAAA=="] {
            #expect(throws: GlassyHostPairingInvitation.ValidationError.invalidCode) {
                try GlassyHostPairingInvitation(scannedValue: valid + suffix, now: now)
            }
        }
    }

    private func versionTwo(identifier: String = "AAAAAAAAAAAAAAAAAAAAAA==", alternates: [String] = []) -> String {
        var components = URLComponents(string: valid)!
        components.queryItems = components.queryItems!.map {
            $0.name == "v" ? URLQueryItem(name: "v", value: "2") : $0
        } + [URLQueryItem(name: "id", value: identifier)]
            + alternates.map { URLQueryItem(name: "alt", value: $0) }
        return components.url!.absoluteString
    }
}
