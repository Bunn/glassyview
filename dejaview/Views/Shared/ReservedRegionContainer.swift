import SwiftUI

/// A stable, expanding container for fixed content that must remain clear of hardware.
/// Scrolling lists should continue across a fold instead of using this container.
struct ReservedRegionContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let regions = activeReservedRegionFrames(in: geometry)
            let rect = ReservedRegionGeometry.largestClearRect(in: bounds, avoiding: regions)

            ReservedRegionLayout(rect: rect) {
                content()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Regions use SwiftUI's default mirroring, matching Layout's automatic RTL placement.
func activeReservedRegionFrames(in geometry: GeometryProxy, includeOcclusions: Bool = true,
                                includeDivisions: Bool = true) -> [CGRect] {
    #if !targetEnvironment(macCatalyst)
    if #available(iOS 27.1, *) {
        let kinds: [ReservedRegion.Kind] = (includeDivisions ? [.division] : [])
            + (includeOcclusions ? [.occlusion] : [])
        return kinds.flatMap { kind in
            geometry.reservedRegions(kind: kind, options: .includeInactive)
                .filter(\.isActive)
                .map(\.frame)
                .filter {
                    let intersection = $0.intersection(CGRect(origin: .zero, size: geometry.size))
                    return !intersection.isNull && !intersection.isEmpty
                }
        }
    }
    #endif
    return []
}

private struct ReservedRegionLayout: Layout {
    let rect: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(rect.size))
        }
    }
}
