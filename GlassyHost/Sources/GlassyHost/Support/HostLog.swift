import OSLog

enum HostLog {
    static let subsystem = "dev.bunn.glassydesk.host"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let encoding = Logger(subsystem: subsystem, category: "Encoding")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let security = Logger(subsystem: subsystem, category: "Security")
}
