import SwiftUI

struct AboutView: View {
    private let developerURL = URL(string: "https://bunn.dev")
    private let royalVNCURL = URL(string: "https://github.com/royalapplications/royalvnc")

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.system(size: 54))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 100, height: 100)
                            .background(.thinMaterial, in: .rect(cornerRadius: 22))

                        Text("Glassy Desk")
                            .font(.title2)
                            .bold()

                        Text("Version \(appVersion) (\(buildNumber))")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical)

                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                if let developerURL {
                    Link(destination: developerURL) {
                        Label("Developer", systemImage: "person")
                    }
                }

                if let royalVNCURL {
                    Link(destination: royalVNCURL) {
                        Label("RoyalVNC", systemImage: "network")
                    }
                }
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
