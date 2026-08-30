import Foundation

enum SubscriptionProductID: String, CaseIterable, Identifiable {
    case lifetime
    case yearly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lifetime:
            String(localized: "Lifetime")
        case .yearly:
            String(localized: "Yearly")
        case .monthly:
            String(localized: "Monthly")
        }
    }

    var fallbackDescription: String {
        switch self {
        case .lifetime:
            String(localized: "One-time access to Glassy Desk Pro.")
        case .yearly:
            String(localized: "Annual access to Glassy Desk Pro.")
        case .monthly:
            String(localized: "Monthly access to Glassy Desk Pro.")
        }
    }

    var packageIdentifierCandidates: Set<String> {
        switch self {
        case .lifetime:
            ["lifetime", "$rc_lifetime"]
        case .yearly:
            ["yearly", "annual", "$rc_annual"]
        case .monthly:
            ["monthly", "$rc_monthly"]
        }
    }
}
