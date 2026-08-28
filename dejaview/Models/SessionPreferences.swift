import Foundation

struct SessionPreferences: Codable, Equatable, Sendable {
    var touchMode: RemoteTouchMode = .direct
    var displaySelection: RemoteDisplaySelection = .all
    var zoomScale = 1.0
    var followsCursor = true
    var pansViewportWithTwoFingers = false
    var frameRate: RemoteFrameRate = .balanced
    var quality: RemoteSessionQuality = .best

    static let `default` = SessionPreferences()

    var normalized: SessionPreferences {
        var preferences = self
        preferences.zoomScale = min(max(zoomScale, 1), 4)
        return preferences
    }

    private enum CodingKeys: String, CodingKey {
        case touchMode
        case displaySelection
        case zoomScale
        case followsCursor
        case pansViewportWithTwoFingers
        case frameRate
        case quality
    }

    init(touchMode: RemoteTouchMode = .direct,
         displaySelection: RemoteDisplaySelection = .all,
         zoomScale: Double = 1,
         followsCursor: Bool = true,
         pansViewportWithTwoFingers: Bool = false,
         frameRate: RemoteFrameRate = .balanced,
         quality: RemoteSessionQuality = .best) {
        self.touchMode = touchMode
        self.displaySelection = displaySelection
        self.zoomScale = zoomScale
        self.followsCursor = followsCursor
        self.pansViewportWithTwoFingers = pansViewportWithTwoFingers
        self.frameRate = frameRate
        self.quality = quality
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        touchMode = try container.decodeIfPresent(RemoteTouchMode.self, forKey: .touchMode) ?? .direct
        displaySelection = try container.decodeIfPresent(RemoteDisplaySelection.self, forKey: .displaySelection) ?? .all
        zoomScale = try container.decodeIfPresent(Double.self, forKey: .zoomScale) ?? 1
        followsCursor = try container.decodeIfPresent(Bool.self, forKey: .followsCursor) ?? true
        pansViewportWithTwoFingers = try container.decodeIfPresent(
            Bool.self,
            forKey: .pansViewportWithTwoFingers
        ) ?? false
        frameRate = try container.decodeIfPresent(RemoteFrameRate.self, forKey: .frameRate) ?? .balanced
        quality = try container.decodeIfPresent(RemoteSessionQuality.self, forKey: .quality) ?? .best
        self = normalized
    }
}
