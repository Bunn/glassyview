struct HostStreamQualityConfiguration: Equatable, Sendable {
    let maximumWidth: Int
    let maximumHeight: Int
    let framesPerSecond: Int
    let averageBitRate: Int

    init(quality: HostProtocol.StreamQuality) {
        switch quality {
        case .dataSaver:
            maximumWidth = 1_280
            maximumHeight = 720
            framesPerSecond = 15
            averageBitRate = 2_000_000
        case .balanced:
            maximumWidth = 1_920
            maximumHeight = 1_080
            framesPerSecond = 30
            averageBitRate = 5_000_000
        case .best:
            maximumWidth = 3_840
            maximumHeight = 2_160
            framesPerSecond = 60
            averageBitRate = 12_000_000
        }
    }

    var screenCaptureConfiguration: ScreenCaptureConfiguration {
        ScreenCaptureConfiguration(
            framesPerSecond: framesPerSecond,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            showsCursor: true
        )
    }

    var encoderConfiguration: H264EncoderConfiguration {
        H264EncoderConfiguration(
            expectedFrameRate: framesPerSecond,
            averageBitRate: averageBitRate,
            keyFrameIntervalSeconds: 2
        )
    }
}
