import Foundation

struct HostUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicEDKey: String

    init?(infoDictionary: [String: Any]) {
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              feed == feed.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: feed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let feedURL = components.url,
              let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
              let keyData = Data(base64Encoded: publicEDKey),
              keyData.count == 32 else {
            return nil
        }

        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }
}
