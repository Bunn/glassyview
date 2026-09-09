import Foundation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case screenSharing
    case pair

    var id: Self { self }
    var isLast: Bool { self == .pair }
    var next: Self { Self(rawValue: rawValue + 1) ?? self }
    var previous: Self { Self(rawValue: rawValue - 1) ?? self }

    var title: String {
        switch self {
        case .welcome:
            String(localized: "a beautiful way to feel right at your Mac.")
        case .screenSharing:
            String(localized: "Screen Sharing.\nBuilt into your Mac.")
        case .pair:
            String(localized: "One scan.\nAnd you’re in.")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            String(localized: "Your apps, files, and favorite shortcuts. All from your iPhone or iPad.")
        case .screenSharing:
            String(localized: "Use standard VNC with your Mac’s built-in Screen Sharing. Turn it on in System Settings → General → Sharing.")
        case .pair:
            String(localized: "Glassy Desk for Mac is an optional faster way to connect. Install it, then scan its code.")
        }
    }
}
