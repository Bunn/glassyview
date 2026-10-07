import Foundation
import Testing
@testable import GlassyDesk

@MainActor
struct AppIntentRouterTests {
    @Test
    func onlyOneSceneClaimsARequest() throws {
        let router = AppIntentRouter()
        router.requestConnection(to: UUID())
        let request = try #require(router.request)

        #expect(router.claim(request))
        #expect(router.request == nil)
        // A second window observing the same change cannot handle it again.
        #expect(!router.claim(request))
    }

    @Test
    func aReplacedRequestCannotBeClaimed() throws {
        let router = AppIntentRouter()
        router.requestOpen(destination: .hosts)
        let staleRequest = try #require(router.request)
        router.requestRefreshNearby()

        #expect(!router.claim(staleRequest))
        #expect(router.request?.action == .refreshNearby)
    }

    @Test
    func disconnectReachesEverySceneWithoutAPendingRequest() throws {
        let router = AppIntentRouter()
        router.requestOpen(destination: .nearby)
        let pending = try #require(router.request)

        router.requestDisconnect()
        router.requestDisconnect()

        #expect(router.disconnectGeneration == 2)
        // Disconnecting does not displace pending navigation work.
        #expect(router.request == pending)
    }
}
