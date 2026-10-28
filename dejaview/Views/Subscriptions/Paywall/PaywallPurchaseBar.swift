import SwiftUI

/// The call to action, its billing terms, and the links App Review expects beside them.
struct PaywallPurchaseBar: View {
    let plan: PaywallPlan?
    let isPurchasing: Bool
    let isRestoring: Bool
    let animates: Bool
    let purchase: () -> Void
    let restore: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PaywallPurchaseButton(title: buttonTitle,
                                  isPurchasing: isPurchasing,
                                  animates: animates,
                                  action: purchase)
                .disabled(plan == nil || isPurchasing || isRestoring)

            Text(terms)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 18)

            HStack(spacing: 6) {
                Button(action: restore) {
                    if isRestoring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Restore")
                    }
                }
                .disabled(isPurchasing || isRestoring)
                .accessibilityIdentifier("subscription.paywall.restore")

                Text(verbatim: "·").foregroundStyle(.tertiary)
                Link("Terms", destination: GlassyDeskLinks.termsOfUse)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Link("Privacy", destination: GlassyDeskLinks.privacyPolicy)
            }
            .font(.footnote.weight(.medium))
            .tint(.secondary)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: plan?.kind)
    }

    private var buttonTitle: String {
        guard let plan else { return String(localized: "Unlock Pro") }
        if plan.freeTrialPeriod != nil {
            return String(localized: "Start Free Trial")
        }
        return plan.kind == .lifetime
            ? String(localized: "Unlock Pro Forever")
            : String(localized: "Unlock Pro")
    }

    private var terms: String {
        guard let plan else { return " " }

        switch (plan.kind, plan.freeTrialPeriod) {
        case (.yearly, let trial?):
            return String(localized: "\(trial) free, then \(plan.price) per year. Cancel anytime.")
        case (.monthly, let trial?):
            return String(localized: "\(trial) free, then \(plan.price) per month. Cancel anytime.")
        case (.yearly, nil):
            return String(localized: "\(plan.price) per year. Renews automatically. Cancel anytime.")
        case (.monthly, nil):
            return String(localized: "\(plan.price) per month. Renews automatically. Cancel anytime.")
        case (.lifetime, _):
            return String(localized: "One payment of \(plan.price). No subscription.")
        }
    }
}

private struct PaywallPurchaseButton: View {
    let title: String
    let isPurchasing: Bool
    let animates: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if isPurchasing {
                    ProgressView()
                        .tint(.white)
                        .transition(.blurReplace)
                } else {
                    HStack(spacing: 8) {
                        Text(title)
                            .contentTransition(.interpolate)
                        Image(systemName: "arrow.right")
                            .font(.headline.weight(.bold))
                    }
                    .transition(.blurReplace)
                }
            }
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(PaywallPalette.actionGradient, in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
            .paywallShimmer(isActive: animates && isEnabled && !isPurchasing)
            .shadow(color: PaywallPalette.deepBlue.opacity(isEnabled ? 0.4 : 0.1), radius: 16, y: 8)
            .saturation(isEnabled || isPurchasing ? 1 : 0.35)
            .brightness(isEnabled || isPurchasing ? 0 : 0.08)
            .contentShape(.capsule)
        }
        .buttonStyle(PurchasePressStyle())
        .animation(.snappy, value: isPurchasing)
        .animation(.snappy, value: title)
        .accessibilityIdentifier("subscription.paywall.purchase")
    }
}

private struct PurchasePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Fine print that sits at the end of the scrolling content.
struct PaywallFinePrint: View {
    var body: some View {
        Text("Payment is charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
    }
}
