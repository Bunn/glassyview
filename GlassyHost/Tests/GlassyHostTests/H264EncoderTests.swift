import Testing
import VideoToolbox
@testable import GlassyHost

@Test("Unsupported optional encoder properties use the encoder default")
func unsupportedOptionalEncoderPropertyFallsBack() {
    #expect(
        H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTPropertyNotSupportedErr,
            requirement: .optional
        )
    )
}

@Test("Unsupported required encoder properties remain fatal")
func unsupportedRequiredEncoderPropertyFails() {
    #expect(
        !H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTPropertyNotSupportedErr,
            requirement: .required
        )
    )
}

@Test("Optional encoder properties surface genuine configuration errors")
func invalidOptionalEncoderPropertyFails() {
    #expect(
        !H264CompressionPropertyPolicy.shouldIgnoreFailure(
            status: kVTParameterErr,
            requirement: .optional
        )
    )
}
