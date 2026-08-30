import Foundation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case setup
    case connect
    case supported

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .welcome:
            String(localized: "Control your Mac")
        case .setup:
            String(localized: "Prepare the Mac")
        case .connect:
            String(localized: "Connect and work")
        case .supported:
            String(localized: "Supported machines")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            String(localized: "Glassy Desk connects your iPhone or iPad to macOS Screen Sharing so you can view and control your desktop from the devices you already carry.")
        case .setup:
            String(localized: "A good session starts with the Mac advertising Screen Sharing and being reachable from your current network.")
        case .connect:
            String(localized: "Use nearby discovery when it is available, or save a host manually for one-tap connections later.")
        case .supported:
            String(localized: "Glassy Desk is tuned for Apple's classic Screen Sharing path over VNC/RFB.")
        }
    }

    var systemImage: String {
        switch self {
        case .welcome:
            "rectangle.connected.to.line.below"
        case .setup:
            "macwindow.and.cursorarrow"
        case .connect:
            "network"
        case .supported:
            "checkmark.seal"
        }
    }

    var bullets: [OnboardingBullet] {
        switch self {
        case .welcome:
            [
                OnboardingBullet(systemImage: "dot.radiowaves.left.and.right",
                                 title: "Find nearby Macs",
                                 detail: "Macs advertising Screen Sharing appear automatically on the Nearby Macs tab."),
                OnboardingBullet(systemImage: "tray.full",
                                 title: "Keep regular hosts close",
                                 detail: "Save names, addresses, ports, and login details for machines you use often."),
                OnboardingBullet(systemImage: "keyboard",
                                 title: "Use touch or a keyboard",
                                 detail: "Tap, drag, scroll, zoom, type, and send common shortcuts during a remote session.")
            ]
        case .setup:
            [
                OnboardingBullet(systemImage: "switch.2",
                                 title: "Turn on Screen Sharing",
                                 detail: "On the Mac, open System Settings > General > Sharing, then enable Screen Sharing or Remote Management."),
                OnboardingBullet(systemImage: "network",
                                 title: "Use a reachable network",
                                 detail: "Your iPhone or iPad and Mac need to be on the same local network, or connected through a VPN that can reach the Mac."),
                OnboardingBullet(systemImage: "powerplug",
                                 title: "Keep the Mac available",
                                 detail: "The Mac must be awake and allowed through any firewall before Glassy Desk can connect.")
            ]
        case .connect:
            [
                OnboardingBullet(systemImage: "plus.circle",
                                 title: "Add or pick a host",
                                 detail: "Tap a nearby Mac, or choose New Machine and enter a hostname, IP address, and port. Screen Sharing usually uses port 5900."),
                OnboardingBullet(systemImage: "person.badge.key",
                                 title: "Sign in with macOS credentials",
                                 detail: "Use a Mac account that is allowed to share the screen. Legacy VNC servers may only need a password."),
                OnboardingBullet(systemImage: "slider.horizontal.3",
                                 title: "Tune each session",
                                 detail: "Session controls include display selection, zoom, trackpad mode, and frame rate.")
            ]
        case .supported:
            [
                OnboardingBullet(systemImage: "desktopcomputer",
                                 title: "Best with Macs",
                                 detail: "Use Macs that expose macOS Screen Sharing or Remote Management over VNC/RFB."),
                OnboardingBullet(systemImage: "server.rack",
                                 title: "Other VNC servers may work",
                                 detail: "Standard VNC/RFB servers can be reachable, but the app is designed and tested around macOS behavior."),
            ]
        }
    }

    var isLast: Bool {
        self == Self.allCases.last
    }

    var next: Self {
        let pages = Self.allCases
        let nextIndex = min(rawValue + 1, pages.count - 1)
        return pages[nextIndex]
    }
}
