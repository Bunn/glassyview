import Testing
@testable import GlassyDesk

struct FeatureFlagsTests {
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
