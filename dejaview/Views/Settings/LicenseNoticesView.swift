import SwiftUI

struct LicenseNoticesView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "License notices are unavailable in this build.")
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Open Source Licenses")
    }
}
