import SwiftUI

struct RemoteConnectionInfoView: View {
    var usesVNC = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Your Mac. Wherever you are.")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("At a café, at work, or on mobile data? Tailscale is a separate VPN app that gives your devices a private connection across different networks.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            Section("Set Up Tailscale") {
                setupStep("Install on both devices", number: "1",
                          detail: "Install Tailscale on your Mac and this iPhone or iPad. Sign in with the same account on both.")
                Link(destination: GlassyDeskLinks.tailscaleDownload) {
                    Label("Get Tailscale", systemImage: "arrow.down.circle")
                }
                setupStep("Allow the VPN connection", number: "2",
                          detail: "Follow Tailscale’s permission prompts, including the Mac’s network extension if requested. Turn Tailscale on and check that both devices show as connected.")
            }

            if usesVNC {
                Section("Connect with Standard VNC") {
                    setupStep("Use your Mac’s Tailscale address", number: "3",
                              detail: "In Tailscale, select your Mac and copy its 100.x.x.x address or full .ts.net name. Enter it as the Mac Address in Standard VNC, with your usual Screen Sharing login and port.")
                }
            } else {
                Section("Pair Before You Go") {
                    setupStep("Scan with Tailscale connected", number: "3",
                              detail: "While you’re at your Mac, open Glassy Desk → Add Device. On this device, choose Add Mac → Set Up Fast Connection → Scan Mac’s Code. Confirm the Mac to save its local and Tailscale addresses.")
                    Text("Already paired before installing Tailscale? Scan a fresh code from the same Mac to add its Tailscale address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                setupStep("Leave your Mac ready", number: "4",
                          detail: usesVNC
                            ? "Keep your Mac awake, online, and Screen Sharing enabled. Leave Tailscale connected on both devices, then open your saved Mac in Glassy Desk."
                            : "Keep your Mac awake and online, with Glassy Desk open and Allow connections enabled. Leave Tailscale connected on both devices, then open your saved Mac as usual.")
            }

            Section {
                if !usesVNC {
                    DisclosureGroup("Pairing manually from another network") {
                        Text("Choose Pair Manually → Enter an address. Copy the Mac’s 100.x.x.x address or full .ts.net name from Tailscale, then enter the current code from Add Device on the Mac. You’ll need access to that code through someone at the Mac or another trusted connection. Setting up before you leave is easiest.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Why isn’t my Mac in Nearby Macs?") {
                    Text("Nearby discovery works on your local network. Away from home, choose your saved Mac or enter its Tailscale address manually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Still can’t connect?") {
                    Text("Check that both devices are online in Tailscale and that your Mac is awake. Another VPN can conflict with Tailscale. If you use a managed Tailscale network, its administrator may need to allow the connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Link(destination: GlassyDeskLinks.remoteSetup) {
                    Label("Read the full setup guide", systemImage: "safari")
                }
                .accessibilityIdentifier("connection.remote-access-website")
            } header: {
                Text("Good to Know")
            } footer: {
                Text("Tailscale handles the private network. You don’t need router port forwarding or an exit node for this setup.")
            }
        }
        .navigationTitle("Connect Away from Home")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupStep(_ title: LocalizedStringKey, number: String,
                           detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.09), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { RemoteConnectionInfoView() }
}
