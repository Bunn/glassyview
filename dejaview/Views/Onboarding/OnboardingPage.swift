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
            String(localized: "View and control your Mac from your iPhone or iPad. Bring your desktop, apps, and familiar shortcuts with you.")
        case .setup:
            String(localized: "Choose Fast Connection for the smoothest experience, or use your Mac’s built-in Screen Sharing with Standard VNC.")
        case .connect:
            String(localized: "Use nearby discovery when it is available, or save a host manually for one-tap connections later.")
        case .supported:
            String(localized: "Fast Connection works with Glassy Desk for Mac. Standard VNC works with macOS Screen Sharing.")
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
                                 title: "Get Glassy Desk for Mac",
                                 detail: "For Fast Connection, install the Mac companion and allow Screen Recording and Accessibility. For Standard VNC, turn on Screen Sharing in your Mac’s Sharing settings."),
                OnboardingBullet(systemImage: "network",
                                 title: "Use a reachable network",
                                 detail: "Use the same Wi-Fi network. To connect away from home, set up Tailscale on both devices with our guide in Settings."),
                OnboardingBullet(systemImage: "powerplug",
                                 title: "Keep the Mac available",
                                 detail: "The Mac must be awake and allowed through any firewall before Glassy Desk can connect.")
            ]
        case .connect:
            [
                OnboardingBullet(systemImage: "plus.circle",
                                 title: "Add or pick a host",
                                 detail: "Choose Add Mac, then Set Up Fast Connection or Standard VNC. You can save either connection for next time."),
                OnboardingBullet(systemImage: "person.badge.key",
                                 title: "Pair with your Mac",
                                 detail: "For Fast Connection, scan the code in Add Device on your Mac or enter it manually. Standard VNC uses your Mac’s Screen Sharing login."),
                OnboardingBullet(systemImage: "slider.horizontal.3",
                                 title: "Tune each session",
                                 detail: "Session controls include display selection, zoom, trackpad mode, and frame rate.")
            ]
        case .supported:
            [
                OnboardingBullet(systemImage: "desktopcomputer",
                                 title: "Best with Macs",
                                 detail: "Glassy Desk for Mac supports macOS 14 or later, on Apple silicon and Intel. Standard VNC uses built-in macOS Screen Sharing."),
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
