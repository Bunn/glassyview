struct HostStreamQualityConfiguration: Equatable, Sendable {
    var maximumWidth: Int
    var maximumHeight: Int
    var framesPerSecond: Int
    var averageBitRate: Int

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

    init(quality: HostProtocol.StreamQuality, availableBitRate: Int?, maximumCaptureWidth: Int? = nil) {
        self.init(quality: quality)
        guard let availableBitRate else { return }
        averageBitRate = max(HostAdaptiveRatePolicy.minimumBitRate, min(averageBitRate, availableBitRate))
        let dimensions: (Int, Int, Int)
        switch averageBitRate {
        case ..<700_000: dimensions = (960, 540, 8)
        case ..<1_500_000: dimensions = (1280, 720, 12)
        case ..<3_000_000: dimensions = (1280, 720, 15)
        case ..<7_000_000: dimensions = (1920, 1080, 30)
        default: dimensions = (3840, 2160, 60)
        }
        maximumWidth = min(maximumWidth, dimensions.0)
        maximumHeight = min(maximumHeight, dimensions.1)
        framesPerSecond = min(framesPerSecond, dimensions.2)
        if let maximumCaptureWidth {
            self.maximumWidth = min(self.maximumWidth, maximumCaptureWidth)
            maximumHeight = min(maximumHeight, maximumCaptureWidth * 9 / 16)
            framesPerSecond = min(framesPerSecond, maximumCaptureWidth <= 320 ? 6 : 8)
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
            keyFrameIntervalSeconds: 2,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight
        )
    }
}
