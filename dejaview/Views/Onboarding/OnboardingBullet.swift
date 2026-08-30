import Foundation

struct OnboardingBullet: Identifiable {
    let systemImage: String
    let title: String
    let detail: String

    init(systemImage: String,
         title: LocalizedStringResource,
         detail: LocalizedStringResource) {
        self.systemImage = systemImage
        self.title = String(localized: title)
        self.detail = String(localized: detail)
    }

    var id: String {
        title
    }
}
