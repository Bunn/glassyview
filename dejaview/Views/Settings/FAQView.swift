import SwiftUI

struct FAQView: View {
    private let connectionItems = [
        SettingsFAQItem(question: "What does Glassy Desk do?",
                        answer: "Glassy Desk connects your iPhone or iPad to a Mac's built-in Screen Sharing service so you can view and control the desktop over VNC/RFB."),
        SettingsFAQItem(question: "Why can I not see my Mac nearby?",
                        answer: "Check that Screen Sharing or Remote Management is enabled on the Mac, both devices are on the same network or VPN, Local Network permission is allowed for Glassy Desk, and the Mac is awake. Some networks block Bonjour discovery, so adding the host manually can still work."),
        SettingsFAQItem(question: "What host and port should I use?",
                        answer: "Use the Mac's local hostname, IP address, or DNS name. macOS Screen Sharing normally listens on port 5900."),
        SettingsFAQItem(question: "How do I use Wake-on-LAN?",
                        answer: "Edit a saved Mac and enter the MAC address of its network interface. Also enable Wake for network access in macOS System Settings. If the Mac is unreachable, tapping its card sends a wake packet and waits up to a minute before connecting. Wake-on-LAN normally requires the devices to be on the same local network or a VPN that forwards broadcasts."),
        SettingsFAQItem(question: "Which credentials should I enter?",
                        answer: "Use the username and password for a Mac account that is allowed to share the screen. If the server uses legacy password-only VNC authentication, leave the username blank and enter the VNC password.")
    ]

    private let compatibilityItems = [
        SettingsFAQItem(question: "Which Macs are supported?",
                        answer: "Glassy Desk is built for Macs exposing macOS Screen Sharing or Remote Management through the classic VNC/RFB path. Multiple displays may appear as separate choices or as one combined desktop depending on what the Mac exposes."),
        SettingsFAQItem(question: "Does it work with non-Mac VNC servers?",
                        answer: "Standard VNC/RFB servers may work, but the app is tuned and tested around macOS Screen Sharing behavior."),
        SettingsFAQItem(question: "Can I connect when away from home?",
                        answer: "Yes, if your iPhone or iPad can reach the Mac through a VPN or routed network. Glassy Desk does not include a cloud relay service."),
        SettingsFAQItem(question: "Does it use Apple's high-performance Screen Sharing protocol?",
                        answer: "No. Third-party clients use the classic VNC/RFB Screen Sharing path exposed by macOS.")
    ]

    private let sessionItems = [
        SettingsFAQItem(question: "What input is supported?",
                        answer: "A session supports taps, drags, right click gestures, scrolling, pinch zoom, hardware keyboard input, and the on-screen shortcut strip."),
        SettingsFAQItem(question: "Where are saved passwords stored?",
                        answer: "Saved machine passwords are stored in the device Keychain. They are used only to authenticate with the machine you choose.")
    ]

    var body: some View {
        Form {
            Section("Getting Connected") {
                ForEach(connectionItems) { item in
                    FAQRow(item: item)
                }
            }

            Section("Compatibility") {
                ForEach(compatibilityItems) { item in
                    FAQRow(item: item)
                }
            }

            Section("Sessions") {
                ForEach(sessionItems) { item in
                    FAQRow(item: item)
                }
            }
        }
        .navigationTitle("FAQ")
    }
}

#Preview {
    NavigationStack {
        FAQView()
    }
}
