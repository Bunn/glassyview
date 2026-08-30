import Foundation

struct SettingsFAQItem: Identifiable {
    let question: String
    let answer: String

    init(question: LocalizedStringResource, answer: LocalizedStringResource) {
        self.question = String(localized: question)
        self.answer = String(localized: answer)
    }

    var id: String {
        question
    }
}
