import SwiftUI

struct FAQView: View {
    private var connectionItems: [SettingsFAQItem] {
        var items = [
            SettingsFAQItem(question: "What does Glassy Desk do?",
                            answer: FeatureFlags.isGlassyStreamEnabled
                                ? "Glassy Desk connects your iPhone or iPad to a Mac so you can view and control its desktop over VNC or Glassy Stream."
                                : "Glassy Desk connects your iPhone or iPad to a Mac's built-in Screen Sharing service so you can view and control the desktop over VNC/RFB."),
            SettingsFAQItem(question: "Why can I not see my Mac nearby?",
                            answer: "Check that Screen Sharing or Remote Management is enabled on the Mac, both devices are on the same network or VPN, Local Network permission is allowed for Glassy Desk, and the Mac is awake. Some networks block Bonjour discovery, so adding the host manually can still work."),
            SettingsFAQItem(question: "What host and port should I use?",
                            answer: FeatureFlags.isGlassyStreamEnabled
                                ? "For VNC, use the Mac's hostname or IP address and normally port 5900. For Glassy Stream, scan its QR code to choose an address automatically, or enter a LAN or VPN address and port 51515."
                                : "Use the Mac's hostname or IP address and normally port 5900 for VNC."),
            SettingsFAQItem(question: "How do I use Wake-on-LAN?",
                            answer: "Edit a saved Mac and enter the MAC address of its network interface. Also enable Wake for network access in macOS System Settings. If the Mac is unreachable, tapping its card sends a wake packet and waits up to a minute before connecting. Wake-on-LAN normally requires the devices to be on the same local network or a VPN that forwards broadcasts."),
            SettingsFAQItem(question: "Which credentials should I enter?",
                            answer: "Use the username and password for a Mac account that is allowed to share the screen. If the server uses legacy password-only VNC authentication, leave the username blank and enter the VNC password.")
        ]

        if FeatureFlags.isGlassyStreamEnabled {
            items.insert(
                SettingsFAQItem(question: "Why is my remote Glassy Host not in the picker?",
                                answer: "Nearby discovery shows Macs on your local network. To pair from another network, connect Tailscale or WireGuard, then scan the Mac’s Glassy Host QR code. Glassy Desk selects a working address automatically and remembers the alternatives."),
                at: 2
            )
            items.insert(
                SettingsFAQItem(question: "Can I pair Glassy Stream with a password?",
                                answer: "Yes, over a trusted Tailscale route. The rotating one-time code remains the default and is required for Nearby or other raw network routes. Configure a reusable password in Glassy Host, connect Tailscale, confirm the selected peer is your Mac, save its Tailscale IP or full .ts.net name, then choose Password. It approves the device once; Glassy Desk keeps only a random device-specific resume credential in Keychain."),
                at: 4
            )
        }

        return items
    }

    private let compatibilityItems = [
        SettingsFAQItem(question: "Which Macs are supported?",
                        answer: "Glassy Desk is built for Macs exposing macOS Screen Sharing or Remote Management through the classic VNC/RFB path. Multiple displays may appear as separate choices or as one combined desktop depending on what the Mac exposes."),
        SettingsFAQItem(question: "Does it work with non-Mac VNC servers?",
                        answer: "Standard VNC/RFB servers may work, but the app is tuned and tested around macOS Screen Sharing behavior."),
        SettingsFAQItem(question: "Can I connect when away from home?",
                        answer: FeatureFlags.isGlassyStreamEnabled
                            ? "Yes. Connect the iPhone or iPad and the Mac with Tailscale or WireGuard, then scan the Mac’s QR code. Glassy Desk automatically uses a reachable local or VPN address. If you paired before configuring the VPN, scan a fresh QR code to add its addresses."
                            : "Yes. Use a trusted VPN such as Tailscale on the iPad and Mac, then save the Mac's VPN address and VNC port. Glassy Desk does not include a cloud relay service."),
        SettingsFAQItem(question: "Does it use Apple's high-performance Screen Sharing protocol?",
                        answer: "No. Third-party clients use the classic VNC/RFB Screen Sharing path exposed by macOS.")
    ]

    private let sessionItems = [
        SettingsFAQItem(question: "What input is supported?",
                        answer: "A session supports taps, drags, right click gestures, scrolling, pinch zoom, hardware keyboard input, and the on-screen shortcut strip."),
        SettingsFAQItem(question: "Where are saved passwords stored?",
                        answer: FeatureFlags.isGlassyStreamEnabled
                            ? "Saved machine credentials are protected by the system. Glassy Stream does not save its reusable pairing password on the iPad; after pairing, it stores only a random device-specific resume credential in Keychain."
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
