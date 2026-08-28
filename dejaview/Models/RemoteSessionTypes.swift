import Foundation
import CoreGraphics

enum RemoteSessionStatus: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(RemoteReconnectState)
    case disconnected(String?)

    var logDescription: String {
        switch self {
        case .idle:
            "idle"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reconnecting(let state):
            "reconnecting(attempt=\(state.attempt),phase=\(String(describing: state.phase)))"
        case .disconnected(let message):
            "disconnected(messageProvided=\(message != nil))"
        }
    }
}

/// User-facing Glassy Stream bandwidth and image-quality presets.
enum RemoteSessionQuality: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case dataSaver
    case balanced
    case best

    var id: Self { self }

    var title: String {
        switch self {
        case .dataSaver:
            "Data Saver"
        case .balanced:
            "Balanced"
        case .best:
            "Best Quality"
        }
    }

    var icon: String {
        switch self {
        case .dataSaver:
            "leaf.fill"
        case .balanced:
            "circle.lefthalf.filled"
        case .best:
            "sparkles"
        }
    }

    var detail: String {
        switch self {
        case .dataSaver:
            "720p · 15 FPS · ~2 Mbps"
        case .balanced:
            "1080p · 30 FPS · ~5 Mbps"
        case .best:
            "Up to 4K · 60 FPS · ~12 Mbps"
        }
    }
}

/// How touches map to the remote pointer.
enum RemoteTouchMode: String, Codable, Equatable, Sendable {
    /// The cursor jumps to wherever you touch.
    case direct
    /// Dragging moves the cursor from where it is, like a trackpad.
    case trackpad
}

enum RemoteScrollDirection {
    case up
    case down
    case left
    case right
}

struct RemoteDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect

    var menuTitle: String {
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())

        return "\(name) (\(width)x\(height))"
    }

    var logDescription: String {
        let minX = Int(frame.minX.rounded())
        let minY = Int(frame.minY.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())

        return "id=\(id) name='\(name)' frame=(x:\(minX),y:\(minY),w:\(width),h:\(height))"
    }
}

enum RemoteDisplaySelection: Hashable, Codable, Sendable {
    case all
    case display(UInt32)
    case region(RemoteDisplayRegion)

    var id: String {
        switch self {
        case .all:
            "all"
        case .display(let id):
            "display-\(id)"
        case .region(let region):
            "region-\(region.rawValue)"
        }
    }

    var logDescription: String {
        switch self {
        case .all:
            "all"
        case .display(let id):
            "display:\(id)"
        case .region(let region):
            "region:\(region.rawValue)"
        }
    }
}

enum RemoteDisplayRegion: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case top
    case bottom

    var title: String {
        switch self {
        case .left:
            "Left Display"
        case .right:
            "Right Display"
        case .top:
            "Top Display"
        case .bottom:
            "Bottom Display"
        }
    }

    var systemImage: String {
        switch self {
        case .left, .right:
            "rectangle.split.2x1"
        case .top, .bottom:
            "rectangle.split.1x2"
        }
    }

    func frame(in bounds: CGRect) -> CGRect {
        switch self {
        case .left:
            let maxX = floor(bounds.midX)
            return CGRect(x: bounds.minX,
                          y: bounds.minY,
                          width: maxX - bounds.minX,
                          height: bounds.height)
        case .right:
            let minX = floor(bounds.midX)
            return CGRect(x: minX,
                          y: bounds.minY,
                          width: bounds.maxX - minX,
                          height: bounds.height)
        case .top:
            let maxY = floor(bounds.midY)
            return CGRect(x: bounds.minX,
                          y: bounds.minY,
                          width: bounds.width,
                          height: maxY - bounds.minY)
        case .bottom:
            let minY = floor(bounds.midY)
            return CGRect(x: bounds.minX,
                          y: minY,
                          width: bounds.width,
                          height: bounds.maxY - minY)
        }
    }
}

struct RemoteDisplayOption: Identifiable, Equatable, Sendable {
    let selection: RemoteDisplaySelection
    let title: String
    let systemImage: String

    var id: String {
        selection.id
    }

    var logDescription: String {
        "\(selection.logDescription) title='\(title)'"
    }
}
