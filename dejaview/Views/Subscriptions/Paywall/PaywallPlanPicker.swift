import SwiftUI

struct PaywallPlanPicker: View {
    let plans: [PaywallPlan]
    @Binding var selection: PaywallPlan.Kind
    let loadFailed: Bool
    let retry: () -> Void

    var body: some View {
        Group {
            if !plans.isEmpty {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(plans) { plan in
                        PaywallPlanCard(plan: plan, isSelected: plan.kind == selection) {
                            selection = plan.kind
                        }
                    }
                }
            } else if loadFailed {
                PaywallPlansUnavailable(retry: retry)
            } else {
                HStack(spacing: 10) {
                    ForEach(PaywallPlan.Kind.allCases, id: \.self) { _ in
                        PaywallPlanPlaceholder()
                    }
                }
            }
        }
        // Leaves room for the badges that sit on the cards' top edges.
        .padding(.top, 10)
        .sensoryFeedback(.selection, trigger: selection)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: selection)
    }
}

private struct PaywallPlanCard: View {
    let plan: PaywallPlan
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                Text(plan.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(plan.price)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(isSelected ? PaywallPalette.selectedFill(for: colorScheme) : PaywallPalette.cardFill(for: colorScheme),
                        in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PaywallPalette.cardStroke(for: colorScheme), lineWidth: 1)
                    .opacity(isSelected ? 0 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PaywallPalette.actionGradient, lineWidth: 2.5)
                    .opacity(isSelected ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                SelectionIndicator(isSelected: isSelected)
                    .padding(8)
            }
            .overlay(alignment: .top) {
                PlanBadge(plan: plan, isSelected: isSelected)
                    .offset(y: -10)
            }
            .shadow(color: PaywallPalette.blue.opacity(isSelected ? 0.25 : 0), radius: 14, y: 6)
            .scaleEffect(isSelected ? 1 : 0.96)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(PlanPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("subscription.paywall.plan.\(String(describing: plan.kind))")
    }

    private var detail: String {
        switch plan.kind {
        case .yearly:
            if let pricePerMonth = plan.pricePerMonth {
                String(localized: "\(pricePerMonth)/month")
            } else {
                String(localized: "per year")
            }
        case .monthly:
            String(localized: "per month")
        case .lifetime:
            String(localized: "one time")
        }
    }
}

private struct PlanBadge: View {
    let plan: PaywallPlan
    let isSelected: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(background, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .fixedSize()
                .scaleEffect(isSelected ? 1.06 : 1)
        }
    }

    private var text: String? {
        if let trial = plan.freeTrialPeriod {
            return String(localized: "\(trial) free")
        }
        if let savings = plan.savings {
            return String(localized: "Save \(savings.formatted(.percent.precision(.fractionLength(0))))")
        }
        return plan.kind == .lifetime ? String(localized: "Pay once") : nil
    }

    private var background: AnyShapeStyle {
        plan.kind == .lifetime
            ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.25),
                                                    Color(red: 0.93, green: 0.36, blue: 0.20)],
                                           startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(PaywallPalette.actionGradient)
    }
}

private struct SelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(PaywallPalette.actionGradient)
                .scaleEffect(isSelected ? 1 : 0.2)

            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.white)
                .scaleEffect(isSelected ? 1 : 0.2)
        }
        .frame(width: 18, height: 18)
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(true)
    }
}

private struct PlanPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct PaywallPlanPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(PaywallPalette.cardFill(for: colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PaywallPalette.cardStroke(for: colorScheme), lineWidth: 1)
            }
            .frame(height: 112)
            .paywallShimmer(isActive: true, interval: 1.6)
            .accessibilityHidden(true)
    }
}

private struct PaywallPlansUnavailable: View {
    let retry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Prices couldn’t be loaded.")
                .font(.headline)
            Text("Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.glass)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(PaywallPalette.cardFill(for: colorScheme), in: .rect(cornerRadius: 22, style: .continuous))
    }
}
