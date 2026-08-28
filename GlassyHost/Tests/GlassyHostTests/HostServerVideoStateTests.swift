import Foundation
import Testing
@testable import GlassyHost

@Test("Codec configuration is scoped to one capture generation")
func codecConfigurationDoesNotSurviveCaptureStop() {
    var cache = HostVideoBootstrapCache()
    let firstConfiguration = Data([0x01, 0x02])
    let secondConfiguration = Data([0x03, 0x04])

    cache.storeCodecConfiguration(firstConfiguration)
    #expect(cache.codecConfiguration == firstConfiguration)

    cache.clear()
    #expect(cache.codecConfiguration == nil)

    cache.storeCodecConfiguration(secondConfiguration)
    #expect(cache.codecConfiguration == secondConfiguration)
}
