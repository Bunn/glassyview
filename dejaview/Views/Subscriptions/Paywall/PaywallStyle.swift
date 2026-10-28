import SwiftUI

/// Colors drawn from the app icon's glass panes, tuned separately for each appearance.
enum PaywallPalette {
    static let sky = Color(red: 0.725, green: 0.863, blue: 0.988)
    static let azure = Color(red: 0.435, green: 0.698, blue: 0.980)
    static let blue = Color(red: 0.184, green: 0.545, blue: 0.976)
    static let deepBlue = Color(red: 0.012, green: 0.275, blue: 0.925)
    static let indigo = Color(red: 0.353, green: 0.322, blue: 0.957)

    /// The prominent call to action reads the same in both appearances.
    static let actionGradient = LinearGradient(colors: [blue, deepBlue, indigo],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing)

    static func titleGradient(for colorScheme: ColorScheme) -> LinearGradient {
        colorScheme == .dark
            ? LinearGradient(colors: [.white, sky], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.70), indigo],
                             startPoint: .leading, endPoint: .trailing)
    }

    static func cardFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.06) : .white.opacity(0.72)
    }

    static func cardStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.12) : Color(red: 0.05, green: 0.2, blue: 0.6).opacity(0.10)
    }

    static func selectedFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? blue.opacity(0.18) : blue.opacity(0.08)
    }
}

/// Fades and lifts content into place, staggered by its position on the page.
struct PaywallEntrance: ViewModifier {
    let order: Int
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 18)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.97)
            .animation(reduceMotion
                       ? .easeOut(duration: 0.2)
                       : .spring(response: 0.6, dampingFraction: 0.82).delay(0.08 * Double(order)),
                       value: isVisible)
    }
}

extension View {
    func paywallEntrance(_ order: Int, isVisible: Bool) -> some View {
        modifier(PaywallEntrance(order: order, isVisible: isVisible))
    }

    /// A band of light that sweeps across the view every few seconds.
    func paywallShimmer(isActive: Bool, interval: Double = 3.6) -> some View {
        modifier(PaywallShimmer(isActive: isActive, interval: interval))
    }
}

private struct PaywallShimmer: ViewModifier {
    let isActive: Bool
    let interval: Double

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    // Sweep during the first second of each interval, then rest.
                    let progress = min(1, elapsed.truncatingRemainder(dividingBy: interval) / 1.1)

                    GeometryReader { geometry in
                        let bandWidth = max(60, geometry.size.width * 0.45)
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.42), .white.opacity(0)],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                            .frame(width: bandWidth)
                            .rotationEffect(.degrees(18))
                            .offset(x: -bandWidth + (geometry.size.width + bandWidth * 2) * progress)
                            .frame(maxHeight: .infinity)
                    }
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .mask(content)
            }
        }
    }
}
