import Testing
@testable import GlassyDesk

struct FeatureFlagsTests {
    @Test("QR-paired Macs remain available for saved-host reconnection")
    func glassyStreamIsAvailableForQRPairing() {
        #expect(FeatureFlags.isGlassyStreamEnabled)
        #expect(RemoteConnectionMode.availableCases.contains(.glassyStream))
    }

    @Test("VNC remains available regardless of feature flags")
    func vncRemainsAvailable() {
        #expect(RemoteConnectionMode.vnc.isEnabled)
        #expect(RemoteConnectionMode.availableCases.contains(.vnc))
    }

    @Test("Glassy Stream availability follows its feature flag")
    func glassyStreamAvailabilityFollowsFeatureFlag() {
        #expect(
            RemoteConnectionMode.glassyStream.isEnabled
                == FeatureFlags.isGlassyStreamEnabled
        )
        #expect(
            RemoteConnectionMode.availableCases.contains(.glassyStream)
                == FeatureFlags.isGlassyStreamEnabled
        )
    }
}
