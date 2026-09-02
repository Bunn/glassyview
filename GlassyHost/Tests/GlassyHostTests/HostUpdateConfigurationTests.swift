import Foundation
import Testing
@testable import GlassyHost

@Test("A complete HTTPS feed and Ed25519 public key enable updates")
func validHostUpdateConfiguration() throws {
    let feed = "https://downloads.example.com/glassy-host/appcast.xml?channel=stable"
    let publicKey = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let configuration = try #require(
        HostUpdateConfiguration(infoDictionary: [
            "SUFeedURL": feed,
            "SUPublicEDKey": publicKey,
        ])
    )

    #expect(configuration.feedURL.absoluteString == feed)
    #expect(configuration.publicEDKey == publicKey)
    #expect(
        configuration == HostUpdateConfiguration(infoDictionary: [
            "SUFeedURL": feed,
            "SUPublicEDKey": publicKey,
        ])
    )
}

@Test("Missing or non-string update settings leave updates unconfigured")
func missingHostUpdateConfiguration() throws {
    let feed = "https://downloads.example.com/appcast.xml"
    let feedURL = try #require(URL(string: feed))
    let publicKey = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let invalidSettings: [[String: Any]] = [
        [:],
        ["SUFeedURL": feed],
        ["SUPublicEDKey": publicKey],
        ["SUFeedURL": 123, "SUPublicEDKey": publicKey],
        ["SUFeedURL": feedURL, "SUPublicEDKey": publicKey],
        ["SUFeedURL": feed, "SUPublicEDKey": 123],
        ["SUFeedURL": feed, "SUPublicEDKey": Data(repeating: 0xA1, count: 32)],
    ]

    for settings in invalidSettings {
        #expect(HostUpdateConfiguration(infoDictionary: settings) == nil)
    }
}

@Test("Update feeds must be exact HTTPS URLs without credentials or fragments")
func invalidHostUpdateFeedURLs() {
    let publicKey = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let invalidFeeds = [
        "",
        "   ",
        "http://downloads.example.com/appcast.xml",
        "file:///tmp/appcast.xml",
        "ftp://downloads.example.com/appcast.xml",
        "/appcast.xml",
        "https:appcast.xml",
        "https:///appcast.xml",
        "https://",
        "https://user@downloads.example.com/appcast.xml",
        "https://user:password@downloads.example.com/appcast.xml",
        "https://downloads.example.com/appcast.xml#stable",
        " https://downloads.example.com/appcast.xml",
        "https://downloads.example.com/appcast.xml ",
        "https://downloads.example.com/appcast.xml\n",
    ]

    for feed in invalidFeeds {
        #expect(
            HostUpdateConfiguration(infoDictionary: [
                "SUFeedURL": feed,
                "SUPublicEDKey": publicKey,
            ]) == nil,
            "The invalid feed must be rejected: \(feed.debugDescription)"
        )
    }
}

@Test("Update public keys must be exact base64-encoded 32-byte keys")
func invalidHostUpdatePublicKeys() {
    let validKey = Data(repeating: 0xA1, count: 32).base64EncodedString()
    let invalidKeys = [
        "",
        "   ",
        "not-a-base64-public-key",
        Data(repeating: 0xA1, count: 31).base64EncodedString(),
        Data(repeating: 0xA1, count: 33).base64EncodedString(),
        " \(validKey)",
        "\(validKey) ",
        "\(validKey)\n",
        "$\(validKey)",
    ]

    for publicKey in invalidKeys {
        #expect(
            HostUpdateConfiguration(infoDictionary: [
                "SUFeedURL": "https://downloads.example.com/appcast.xml",
                "SUPublicEDKey": publicKey,
            ]) == nil,
            "The invalid key must be rejected: \(publicKey.debugDescription)"
        )
    }
}
