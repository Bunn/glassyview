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

@Test("Shared stream quality follows the most bandwidth-conscious viewer")
func conservativeStreamQualityArbitration() {
    var arbitration = HostStreamQualityArbitration()

    #expect(
        HostStreamQualityArbitration.effectiveQuality(
            for: [HostProtocol.StreamQuality]()
        ) == .best
    )
    #expect(arbitration.qualityToPublish(for: [.best]) == nil)
    #expect(arbitration.qualityToPublish(for: [.best, .balanced]) == .balanced)
    #expect(arbitration.qualityToPublish(for: [.best, .balanced]) == nil)
    #expect(arbitration.qualityToPublish(for: [.balanced, .best]) == nil)
    #expect(
        arbitration.qualityToPublish(for: [.best, .balanced, .dataSaver])
            == .dataSaver
    )

    // Removing the most constrained viewer permits the shared stream to upgrade.
    #expect(arbitration.qualityToPublish(for: [.best, .balanced]) == .balanced)
    #expect(arbitration.qualityToPublish(for: [.best]) == .best)
    #expect(arbitration.qualityToPublish(for: []) == nil)
    #expect(arbitration.qualityToPublish(for: [], force: true) == .best)
}

@Test("Identical decoder configuration is not republished across encoder recreation")
func identicalCodecConfigurationDoesNotResetViewer() {
    var cache = HostVideoBootstrapCache()
    let configuration = Data([0x67, 0x01, 0x68, 0x02])
    #expect(cache.storeCodecConfiguration(configuration) == true)
    #expect(cache.storeCodecConfiguration(configuration) == false)
    #expect(cache.storeCodecConfiguration(Data([0x67, 0x03, 0x68, 0x04])) == true)
    cache.clear()
    #expect(cache.storeCodecConfiguration(configuration) == true)
}
