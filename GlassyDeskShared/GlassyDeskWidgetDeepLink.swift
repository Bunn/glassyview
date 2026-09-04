import Foundation

enum GlassyDeskWidgetDeepLink: Equatable, Sendable {
    case hosts
    case connect(UUID)

    private static let scheme = "glassydesk"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .hosts:
            components.host = "hosts"
        case .connect(let machineID):
            components.host = "connect"
            components.queryItems = [URLQueryItem(name: "machine", value: machineID.uuidString)]
        }

        return components.url!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty else {
            return nil
        }

        switch components.host {
        case "hosts":
            guard components.queryItems == nil else { return nil }
            self = .hosts
        case "connect":
            guard let queryItems = components.queryItems,
                  queryItems.count == 1,
                  queryItems[0].name == "machine",
                  let value = queryItems[0].value,
                  let machineID = UUID(uuidString: value) else {
                return nil
            }
            self = .connect(machineID)
        default:
            return nil
        }
    }
}
