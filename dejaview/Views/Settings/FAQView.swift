import SwiftUI

struct FAQView: View {
    private var connectionItems: [SettingsFAQItem] {
        var items = [
            SettingsFAQItem(question: "What does Glassy Desk do?",
                            answer: FeatureFlags.isGlassyStreamEnabled
                                ? "Glassy Desk connects your iPhone or iPad to a Mac so you can view and control its desktop over VNC or Fast Connection."
                                : "Glassy Desk connects your iPhone or iPad to a Mac's built-in Screen Sharing service so you can view and control the desktop over VNC/RFB."),
            SettingsFAQItem(question: "Why can I not see my Mac nearby?",
                            answer: "Check that Screen Sharing or Remote Management is enabled on the Mac, both devices are on the same network or VPN, Local Network permission is allowed for Glassy Desk, and the Mac is awake. Some networks block Bonjour discovery, so adding the host manually can still work."),
            SettingsFAQItem(question: "What host and port should I use?",
                            answer: FeatureFlags.isGlassyStreamEnabled
                                ? "For VNC, use the Mac's hostname or IP address and normally port 5900. For Fast Connection, scan its QR code to choose an address automatically, or enter a LAN or VPN address and port 51515."
                                : "Use the Mac's hostname or IP address and normally port 5900 for VNC."),
            SettingsFAQItem(question: "How do I use Wake-on-LAN?",
                            answer: "Edit a saved Mac and enter the MAC address of its network interface. Also enable Wake for network access in macOS System Settings. If the Mac is unreachable, tapping its card sends a wake packet and waits up to a minute before connecting. Wake-on-LAN normally requires the devices to be on the same local network or a VPN that forwards broadcasts."),
            SettingsFAQItem(question: "Which credentials should I enter?",
                            answer: "Use the username and password for a Mac account that is allowed to share the screen. If the server uses legacy password-only VNC authentication, leave the username blank and enter the VNC password.")
        ]

        if FeatureFlags.isGlassyStreamEnabled {
            items.insert(
                SettingsFAQItem(question: "Why is my remote Mac not shown nearby?",
                                answer: "Nearby discovery only shows Macs on your local network. From elsewhere, connect Tailscale on both devices and use your saved Mac or its Tailscale address. Open Connect away from home in Settings for the full guide."),
                at: 2
            )
            items.insert(
                SettingsFAQItem(question: "Can I pair Fast Connection with a password?",
                                answer: "Yes, over a trusted Tailscale route. The rotating one-time code remains the default and is required for Nearby or other raw network routes. Configure a reusable password in Glassy Desk, connect Tailscale, confirm the selected peer is your Mac, save its Tailscale IP or full .ts.net name, then choose Password. It approves the device once; Glassy Desk keeps only a random device-specific resume credential in Keychain."),
                at: 4
            )
        }

        return items
    }

    private let compatibilityItems = [
        SettingsFAQItem(question: "Which Macs are supported?",
                        answer: "Fast Connection supports Macs running Glassy Desk for Mac on macOS 14 or later, with Apple silicon or Intel. Standard VNC uses macOS Screen Sharing. Display choices depend on the connection and the Mac’s setup."),
        SettingsFAQItem(question: "Does it work with non-Mac VNC servers?",
                        answer: "Standard VNC/RFB servers may work, but the app is tuned and tested around macOS Screen Sharing behavior."),
        SettingsFAQItem(question: "Can I connect when away from home?",
                        answer: FeatureFlags.isGlassyStreamEnabled
                            ? "Yes. Set up Tailscale on the Mac and your iPhone or iPad, then pair while you’re at your Mac with Tailscale connected. Keep the Mac awake and online. Open Connect away from home in Settings for the full guide, including manual pairing."
                            : "Yes. Use a trusted VPN such as Tailscale on the iPad and Mac, then save the Mac's VPN address and VNC port. Glassy Desk does not include a cloud relay service."),
        SettingsFAQItem(question: "Does it use Apple's high-performance Screen Sharing protocol?",
                        answer: "No. Fast Connection uses Glassy Desk’s own streaming connection through the Mac companion. Standard VNC uses the classic VNC/RFB Screen Sharing service.")
    ]

    private let sessionItems = [
        SettingsFAQItem(question: "What input is supported?",
                        answer: "A session supports taps, drags, right click gestures, scrolling, pinch zoom, hardware keyboard input, and the on-screen shortcut strip."),
        SettingsFAQItem(question: "Where are saved passwords stored?",
                        answer: FeatureFlags.isGlassyStreamEnabled
                            ? "Saved machine credentials are protected by the system. Glassy Desk does not save its reusable pairing password on the iPad; after pairing, it stores only a random device-specific resume credential in Keychain."
                            : "Saved machine credentials are protected by the system Keychain.")
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
