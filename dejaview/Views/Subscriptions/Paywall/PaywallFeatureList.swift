import SwiftUI

/// What Pro adds, in the order people feel it: the clock goes away first.
struct PaywallFeatureList: View {
    let isVisible: Bool
    let animates: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(PaywallFeature.allCases.enumerated()), id: \.element) { index, feature in
                PaywallFeatureRow(feature: feature, isVisible: isVisible, animates: animates)
                    .paywallEntrance(index + 2, isVisible: isVisible)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaywallPalette.cardFill(for: colorScheme), in: .rect(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(PaywallPalette.cardStroke(for: colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 20, y: 10)
    }
}

enum PaywallFeature: CaseIterable {
    case unlimited
    case longJobs
    case everyFeature
    case appIcons

    var title: LocalizedStringKey {
        switch self {
        case .unlimited: "Unlimited sessions"
        case .longJobs: "Made for long jobs"
        case .everyFeature: "Every feature, uninterrupted"
        case .appIcons: "Five Pro app icons"
        }
    }

    /// The app icon row shows the icons themselves instead.
    var detail: LocalizedStringKey? {
        switch self {
        case .unlimited: "No one-minute cap. No 90-second break."
        case .longJobs: "Watch builds, renders, and AI agents finish."
        case .everyFeature: "Picture in Picture, files, and Curtain Mode."
        case .appIcons: nil
        }
    }

    var systemImage: String {
        switch self {
        case .unlimited: "infinity"
        case .longJobs: "hammer.fill"
        case .everyFeature: "pip.fill"
        case .appIcons: "paintbrush.pointed.fill"
        }
    }

    var tint: [Color] {
        switch self {
        case .unlimited: [PaywallPalette.blue, PaywallPalette.deepBlue]
        case .longJobs: [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.95, green: 0.38, blue: 0.16)]
        case .everyFeature: [Color(red: 0.62, green: 0.45, blue: 1.0), Color(red: 0.42, green: 0.27, blue: 0.92)]
        case .appIcons: [Color(red: 0.25, green: 0.85, blue: 0.80), Color(red: 0.08, green: 0.62, blue: 0.68)]
        }
    }
}

private struct PaywallFeatureRow: View {
    let feature: PaywallFeature
    let isVisible: Bool
    let animates: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce.up, value: isVisible)
                .frame(width: 40, height: 40)
                .background(LinearGradient(colors: feature.tint, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.75)
                }
                .shadow(color: feature.tint[1].opacity(0.35), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline)
                if let detail = feature.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProIconStrip(animates: animates)
                        .padding(.top, 4)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The real alternate icons, bobbing gently in a wave.
private struct ProIconStrip: View {
    let animates: Bool

    private let icons = AppIconOption.allCases.filter(\.requiresPro)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0

            HStack(spacing: 7) {
                ForEach(Array(icons.enumerated()), id: \.element) { index, icon in
                    Image(icon.previewImageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .clipShape(.rect(cornerRadius: 7.5, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                        .offset(y: sin(time * 2.2 - Double(index) * 0.7) * 3)
                        .rotationEffect(.degrees(sin(time * 1.6 - Double(index) * 0.9) * 3))
                }
            }
        }
        .accessibilityLabel("Midnight, Graphite, Violet, Mint, and Sunset")
    }
}
