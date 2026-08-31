import Foundation
import Testing
@testable import GlassyDesk

struct SessionPreferencesTests {
    @Test
    func trackpadDotDefaultsToOff() {
        #expect(!SessionPreferences.default.showsTrackpadCursorDot)
    }

    @Test
    func legacyPreferencesDefaultTrackpadDotToOff() throws {
        let preferences = try JSONDecoder().decode(
            SessionPreferences.self,
            from: Data("{}".utf8)
        )

        #expect(!preferences.showsTrackpadCursorDot)
    }

    @Test
    func trackpadDotPreferenceRoundTrips() throws {
        let expected = SessionPreferences(showsTrackpadCursorDot: true)

        let encoded = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(SessionPreferences.self, from: encoded)

        #expect(decoded.showsTrackpadCursorDot)
    }
}
