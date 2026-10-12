import Foundation

/// The Home Screen icons bundled with the app. Every option except
/// `classic` is an alternate icon reserved for Glassy Desk Pro.
enum AppIconOption: String, CaseIterable, Identifiable {
    case classic
    case midnight
    case graphite
    case violet
    case mint
    case sunset

    var id: String { rawValue }

    /// The name `UIApplication` expects; `nil` selects the primary icon.
    var alternateIconName: String? {
        switch self {
        case .classic: nil
        case .midnight: "AppIconMidnight"
        case .graphite: "AppIconGraphite"
        case .violet: "AppIconViolet"
        case .mint: "AppIconMint"
        case .sunset: "AppIconSunset"
        }
    }

    var previewImageName: String {
        alternateIconName ?? "AppIcon"
    }

    var requiresPro: Bool {
        self != .classic
    }

    var title: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .midnight: String(localized: "Midnight")
        case .graphite: String(localized: "Graphite")
        case .violet: String(localized: "Violet")
        case .mint: String(localized: "Mint")
        case .sunset: String(localized: "Sunset")
        }
    }

    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .classic
    }
}
