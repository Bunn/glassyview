import AppKit
import Foundation
import Testing
import Vision
@testable import GlassyHost

private let inviteExpiry = Date(timeIntervalSince1970: 2_000_000_000)
private let inviteHostIdentifier = Data(repeating: 0xfb, count: HostProtocol.identifierLength)

@Test("Pairing invitation URL preserves reserved and Unicode display names")
func pairingInviteURLRoundTrip() throws {
    let invite = HostPairingInvite(
        host: "studio-mac.local", port: 51_515, name: "Áine’s Mac + Display & Audio",
        code: "ABCDEFGH2345", expiresAt: inviteExpiry, hostIdentifier: inviteHostIdentifier
    )
    let url = try #require(invite.urlString)
    let components = try #require(URLComponents(string: url))
    let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(components.scheme == "glassydesk")
    #expect(components.host == "pair")
    #expect(components.path.isEmpty)
    #expect(fields["v"] == "2")
    #expect(fields["host"] == invite.host)
    #expect(fields["port"] == "51515")
    #expect(fields["name"] == invite.name)
    #expect(fields["code"] == invite.code)
    #expect(fields["expires"] == "2000000000")
    #expect(fields["id"] == inviteHostIdentifier.base64EncodedString())
    #expect(!url.contains("+"))
    #expect(fields.count == 7)
}

@Test("Pairing invitations reject unusable endpoint and credential fields")
func pairingInviteValidation() {
    func invite(host: String = "studio.local", port: UInt16 = 51_515, name: String = "Studio Mac", code: String = "ABCDEFGH2345", expiresAt: Date = inviteExpiry) -> HostPairingInvite {
        HostPairingInvite(host: host, port: port, name: name, code: code, expiresAt: expiresAt, hostIdentifier: inviteHostIdentifier)
    }
    for host in ["", "http://studio.local", "studio.local/path", " studio.local", "studio..local", "-studio.local", String(repeating: "a", count: 64) + ".local"] {
        #expect(invite(host: host).urlString == nil)
    }
    #expect(invite(port: 0).urlString == nil)
    #expect(invite(name: "  ").urlString == nil)
    #expect(invite(name: " Studio Mac").urlString == nil)
    #expect(invite(name: "Studio Mac ").urlString == nil)
    #expect(invite(name: "Mac\nStudio").urlString == nil)
    #expect(invite(name: "Mac\u{202E}Studio").urlString == nil)
    #expect(invite(name: String(repeating: "a", count: 256)).urlString == nil)
    #expect(invite(name: String(repeating: "🖥", count: 64)).urlString == nil)
    for code in ["ABCDE", "ABCDEFGHI234", "ABCDEFGH2340", "abcdefgh2345", "ABCD EFGH 23"] {
        #expect(invite(code: code).urlString == nil)
    }
    #expect(invite(expiresAt: Date(timeIntervalSince1970: .infinity)).urlString == nil)
    #expect(invite(expiresAt: Date(timeIntervalSince1970: -1)).urlString == nil)
    #expect(invite(host: "192.168.1.42").urlString != nil)
    #expect(invite(host: "fd12:3456:789a:1::42").urlString != nil)
}

@Test("Custom pairing QR codes decode exactly at their displayed size", arguments: [
    ("studio-mac.local", "Studio Mac"),
    ("192.168.123.234", "Áine’s Mac + Display & Audio"),
    ("fd12:3456:789a:abcd:1234:5678:90ab:cdef", "Design and Engineering — Mac Studio (Meeting Room 4)"),
    (String(repeating: "long-host-", count: 5) + "studio.local", Array(repeating: "Mac Studio", count: 9).joined(separator: " "))
])
func pairingQRCodeRoundTrip(host: String, name: String) throws {
    let payload = try #require(HostPairingInvite(
        host: host, port: 51_515, name: name, code: "ABCDEFGH2345", expiresAt: inviteExpiry, hostIdentifier: inviteHostIdentifier
    ).urlString)
    try expectDecodablePairingQR(payload)
}

@Test("Version 2 invitations preserve ordered alternative addresses and a canonical host identity")
func pairingInviteMultipleAddressesRoundTrip() throws {
    let addresses = ["100.102.22.80", "192.168.1.42", "FD7A:115C:A1E0::42", "10.8.0.2", "studio.local"]
    let invite = HostPairingInvite(
        host: addresses[0], port: 51_515, name: "Studio Mac", code: "ABCDEFGH2345", expiresAt: inviteExpiry,
        hostIdentifier: inviteHostIdentifier, alternateHosts: Array(addresses.dropFirst())
    )
    let url = try #require(invite.urlString)
    let items = try #require(URLComponents(string: url)?.queryItems)
    #expect(items.filter { $0.name == "alt" }.compactMap(\.value) == ["192.168.1.42", "fd7a:115c:a1e0::42", "10.8.0.2", "studio.local"])
    #expect(items.first { $0.name == "host" }?.value == addresses[0])
    #expect(items.first { $0.name == "id" }?.value == inviteHostIdentifier.base64EncodedString())
}

@Test("Version 2 invitations reject duplicate endpoints, invalid identities and excessive payloads")
func pairingInviteMultipleAddressesValidation() {
    func invite(host: String = "100.102.22.80", alternatives: [String] = [], identifier: Data = inviteHostIdentifier,
                name: String = "Studio Mac") -> HostPairingInvite {
        HostPairingInvite(host: host, port: 51_515, name: name, code: "ABCDEFGH2345", expiresAt: inviteExpiry,
                          hostIdentifier: identifier, alternateHosts: alternatives)
    }
    #expect(invite(alternatives: ["100.102.22.80"]).urlString == nil)
    #expect(invite(host: "Studio.local", alternatives: ["studio.local"]).urlString == nil)
    #expect(invite(host: "fd12::42", alternatives: ["FD12:0:0:0:0:0:0:42"]).urlString == nil)
    #expect(invite(alternatives: ["fe80::42%utun4"]).urlString == nil)
    #expect(invite(alternatives: ["0.0.0.0"]).urlString == nil)
    #expect(invite(identifier: Data(repeating: 1, count: 15)).urlString == nil)
    #expect(invite(alternatives: (1...8).map { "10.8.0.\($0)" }).urlString == nil)
    let longAddresses = (1...8).map { index in
        "\(index)" + String(repeating: "a", count: 62) + "." + String(repeating: "b", count: 63)
            + "." + String(repeating: "c", count: 63) + "." + String(repeating: "d", count: 61)
    }
    #expect(invite(host: longAddresses[0], alternatives: Array(longAddresses.dropFirst()), name: String(repeating: "🖥", count: 63)).urlString == nil)
}

@Test("Dense IPv6 and eight-address VPN pairing invitations decode at display size", arguments: [
    ["100.102.22.80", "192.168.123.234", "fd7a:115c:a1e0:ab12:1234:5678:90ab:cdef", "10.8.0.2", "fd12:3456:789a:abcd:1234:5678:90ab:cdef", "2001:db8:1234:5678:90ab:cdef:1234:5678", "192.168.8.42", "studio-mac.local"],
    (1...8).map { "fd12:3456:789a:abcd:1234:5678:90ab:cde\($0)" }
])
func pairingQRCodeDenseMultipleAddresses(addresses: [String]) throws {
    let payload = try #require(HostPairingInvite(
        host: addresses[0], port: 51_515, name: "Áine’s Mac Studio — Design, Video + Engineering", code: "ABCDEFGH2345", expiresAt: inviteExpiry,
        hostIdentifier: inviteHostIdentifier, alternateHosts: Array(addresses.dropFirst())
    ).urlString)
    #expect(payload.utf8.count <= 2_048)
    try expectDecodablePairingQR(payload)
}

private func expectDecodablePairingQR(_ payload: String) throws {
    let image = try #require(HostPairingQRCode.image(for: payload))
    #expect(image.size == NSSize(width: 300, height: 300))
    var rect = CGRect(origin: .zero, size: image.size)
    let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    let context = try #require(CGContext(
        data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 300,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.interpolationQuality = .high
    context.draw(cgImage, in: rect)
    let displayedImage = try #require(context.makeImage())
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: displayedImage).perform([request])
    #expect(request.results?.first?.payloadStringValue == payload)

    // The complete outer margin stays opaque white. Inspect full-resolution
    // pixels so this also catches accidental marks in the scanner's quiet zone.
    let raw = try #require(cgImage.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(raw))
    let border = 4 * 10
    #expect(cgImage.bitsPerPixel == 8)
    let quietZoneIsWhite = (0..<cgImage.height).allSatisfy { y in
        (0..<cgImage.width).allSatisfy { x in
            let isMargin = x < border || y < border
                || x >= cgImage.width - border || y >= cgImage.height - border
            return !isMargin || bytes[y * cgImage.bytesPerRow + x] == 255
        }
    }
    #expect(quietZoneIsWhite)
}

@Test("QR generation rejects empty and oversized content")
func pairingQRCodeInvalidPayload() {
    #expect(HostPairingQRCode.image(for: "") == nil)
    #expect(HostPairingQRCode.image(for: String(repeating: "a", count: 2_049)) == nil)
}
