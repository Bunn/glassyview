import Foundation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case pair

    var id: Self { self }
    var isLast: Bool { self == .pair }

    var title: String {
        switch self {
        case .welcome:
            String(localized: "Your Mac.\nRight here.")
        case .pair:
            String(localized: "One scan.\nAnd you’re in.")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            String(localized: "Your apps, files, and favorite shortcuts. All from your iPhone or iPad.")
        case .pair:
            String(localized: "Open Glassy Desk on your Mac, then scan its code to connect.")
        }
    }
}
