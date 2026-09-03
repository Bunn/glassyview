import AppKit
import Foundation
import Testing
import Vision
@testable import GlassyHost

private let inviteExpiry = Date(timeIntervalSince1970: 2_000_000_000)

@Test("Pairing invitation URL preserves reserved and Unicode display names")
func pairingInviteURLRoundTrip() throws {
    let invite = HostPairingInvite(
        host: "studio-mac.local", port: 51_515, name: "Áine’s Mac + Display & Audio",
        code: "ABCDEFGH2345", expiresAt: inviteExpiry
    )
    let url = try #require(invite.urlString)
    let components = try #require(URLComponents(string: url))
    let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(components.scheme == "glassydesk")
    #expect(components.host == "pair")
    #expect(components.path.isEmpty)
    #expect(fields["v"] == "1")
    #expect(fields["host"] == invite.host)
    #expect(fields["port"] == "51515")
    #expect(fields["name"] == invite.name)
    #expect(fields["code"] == invite.code)
    #expect(fields["expires"] == "2000000000")
    #expect(fields.count == 6)
}

@Test("Pairing invitations reject unusable endpoint and credential fields")
func pairingInviteValidation() {
    func invite(host: String = "studio.local", port: UInt16 = 51_515, name: String = "Studio Mac", code: String = "ABCDEFGH2345", expiresAt: Date = inviteExpiry) -> HostPairingInvite {
        HostPairingInvite(host: host, port: port, name: name, code: code, expiresAt: expiresAt)
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
        host: host, port: 51_515, name: name, code: "ABCDEFGH2345", expiresAt: inviteExpiry
    ).urlString)
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
