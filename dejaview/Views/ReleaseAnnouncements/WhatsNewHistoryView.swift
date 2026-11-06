import SwiftUI

/// Every release's notes, newest first, opened from Settings. Reading them here
/// doesn't count as announcing a release, so it never skips the launch screen.
struct WhatsNewHistoryView: View {
    var releases = WhatsNewRelease.all

    var body: some View {
        List {
            ForEach(releases) { release in
                Section {
                    ForEach(release.features) { feature in
                        WhatsNewHistoryRow(feature: feature)
                    }
                } header: {
                    Text("Version \(release.id)")
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    if let footnote = release.footnote {
                        Text(footnote)
                    }
                }
            }
        }
        .navigationTitle("What's New")
        .accessibilityIdentifier("settings.whatsNew")
    }
}

private struct WhatsNewHistoryRow: View {
    let feature: WhatsNewRelease.Feature

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.body.weight(.semibold))
                // The tile stays a fixed size, so the symbol has to fit inside it.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(PaywallPalette.actionGradient, in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        WhatsNewHistoryView()
    }
}
