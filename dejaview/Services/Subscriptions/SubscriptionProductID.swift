import Foundation

enum SubscriptionProductID: String, CaseIterable, Identifiable {
    case lifetime
    case yearly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lifetime:
            "Lifetime"
        case .yearly:
            "Yearly"
        case .monthly:
            "Monthly"
        }
    }

    var fallbackDescription: String {
        switch self {
        case .lifetime:
            "One-time access to Glassy Desk Pro."
        case .yearly:
            "Annual access to Glassy Desk Pro."
        case .monthly:
            "Monthly access to Glassy Desk Pro."
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
