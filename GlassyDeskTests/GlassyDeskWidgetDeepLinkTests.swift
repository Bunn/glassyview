import Foundation
import Testing
@testable import GlassyDesk

struct GlassyDeskWidgetDeepLinkTests {
    private let machineID = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-1234567890AB")!

    @Test
    func canonicalRoutesRoundTrip() {
        let connect = GlassyDeskWidgetDeepLink.connect(machineID)
        #expect(connect.url.absoluteString == "glassydesk://connect?machine=A1B2C3D4-E5F6-4789-ABCD-1234567890AB")
        #expect(GlassyDeskWidgetDeepLink(url: connect.url) == connect)

        let hosts = GlassyDeskWidgetDeepLink.hosts
        #expect(hosts.url.absoluteString == "glassydesk://hosts")
        #expect(GlassyDeskWidgetDeepLink(url: hosts.url) == hosts)
    }

    @Test(arguments: [
        "https://connect?machine=A1B2C3D4-E5F6-4789-ABCD-1234567890AB",
        "GLASSYDESK://connect?machine=A1B2C3D4-E5F6-4789-ABCD-1234567890AB",
        "glassydesk://connect/A1B2C3D4-E5F6-4789-ABCD-1234567890AB",
        "glassydesk://connect",
        "glassydesk://connect?machine=not-a-uuid",
        "glassydesk://connect?machine=A1B2C3D4-E5F6-4789-ABCD-1234567890AB&extra=true",
        "glassydesk://connect?machine=A1B2C3D4-E5F6-4789-ABCD-1234567890AB#fragment",
        "glassydesk://hosts/",
        "glassydesk://hosts?extra=true",
        "glassydesk://unknown"
    ])
    func rejectsMalformedOrAmbiguousRoutes(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(GlassyDeskWidgetDeepLink(url: url) == nil)
    }
}
