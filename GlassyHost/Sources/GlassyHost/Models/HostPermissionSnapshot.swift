import Foundation

struct HostPermissionSnapshot: Codable, Equatable, Sendable {
    let screenRecording: Bool
    let accessibility: Bool
}
