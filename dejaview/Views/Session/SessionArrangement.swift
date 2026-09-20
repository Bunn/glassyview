import SwiftUI

/// One geometry owner assigns both panes. Neither child independently chooses
/// a side of the fold, and changing the division never replaces the desktop.
struct SessionArrangement<Content: View, Controls: View>: View {
    var overlayBottomInset: CGFloat = 0
    var usesDividedLayout = true
    var onSeparationChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @ViewBuilder var controls: () -> Controls

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { visibleGeometry in
            Color.clear
                .allowsHitTesting(false)
                .background(alignment: .topLeading) {
                    // Both readers participate in this layout pass. Retaining a
                    // previous reader value in State mixed old fold coordinates
                    // with new window bounds during rotation.
                    GeometryReader { unobscuredGeometry in
                        let snapshot = SessionPaneSnapshot(unobscuredGeometry)
                        let frames = SessionPaneGeometry.frames(
                            in: CGRect(origin: .zero, size: snapshot.size),
                            divisions: usesDividedLayout ? snapshot.divisions : [],
                            occlusions: snapshot.occlusions + (usesDividedLayout ? [] : snapshot.divisions)
                        )
                        let visibleBounds = SessionPaneCoordinates.visibleBounds(
                            visibleGlobalFrame: visibleGeometry.frame(in: .global),
                            unobscuredGlobalFrame: unobscuredGeometry.frame(in: .global),
                            layoutDirection: layoutDirection
                        )
                        let contentFrame = visiblePart(of: frames.content, in: visibleBounds)
                        let controlsFrame = visiblePart(of: frames.controls, in: visibleBounds)
                        let isProtected = !snapshot.divisions.isEmpty || !snapshot.occlusions.isEmpty
                        let bottomInset = frames.isSeparated ? 0 : overlayBottomInset
                        let toolbarFitsControls = controlsFrame.width >= 156 && controlsFrame.height >= 56

                        SessionPaneLayout(contentFrame: contentFrame, controlsFrame: controlsFrame) {
                            content()
                                .environment(\.remoteContentRespectsContainer, isProtected)
                                .environment(\.remoteContentOverlayBottomInset, bottomInset)
                                .environment(\.remoteContentFittingSize,
                                             frames.isSeparated ? contentFrame.size : (isProtected ? frames.content.size : nil))
                                .safeAreaInset(edge: .bottom, spacing: 0) {
                                    Color.clear.frame(height: bottomInset).allowsHitTesting(false)
                                }
                            controls()
                                // A covered keyboard responder must stay enabled;
                                // disabling it can reenter keyboard layout.
                                .clipped()
                        }
                        .environment(\.foldedToolbarUsesControlsPane, toolbarFitsControls)
                        .frame(width: snapshot.size.width, height: snapshot.size.height)
                        .onChange(of: frames.isSeparated, initial: true) { _, separated in
                            onSeparationChange(separated)
                        }
                    }
                    // Query the full local fold even when the keyboard covers
                    // the controller, then clip assigned frames to visible space.
                    .ignoresSafeArea(.keyboard)
                }
        }
    }

    private func visiblePart(of frame: CGRect, in bounds: CGRect) -> CGRect {
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull else {
            return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX),
                          y: min(max(frame.minY, bounds.minY), bounds.maxY), width: 0, height: 0)
        }
        return intersection
    }
}

/// Converts physical global frames into the same logical local coordinates as
/// reserved-region queries and SwiftUI Layout. RTL mirrors the horizontal offset
/// once; it does not mirror the system's already-local reserved-region frames.
enum SessionPaneCoordinates {
    static func visibleBounds(visibleGlobalFrame: CGRect, unobscuredGlobalFrame: CGRect,
                              layoutDirection: LayoutDirection) -> CGRect {
        CGRect(x: layoutDirection == .rightToLeft
               ? unobscuredGlobalFrame.maxX - visibleGlobalFrame.maxX
               : visibleGlobalFrame.minX - unobscuredGlobalFrame.minX,
               y: visibleGlobalFrame.minY - unobscuredGlobalFrame.minY,
               width: visibleGlobalFrame.width, height: visibleGlobalFrame.height)
    }
}

private struct SessionPaneSnapshot: Equatable {
    let size: CGSize
    let divisions: [CGRect]
    let occlusions: [CGRect]

    init(_ geometry: GeometryProxy) {
        size = geometry.size
        divisions = activeReservedRegionFrames(in: geometry, includeOcclusions: false)
        occlusions = activeReservedRegionFrames(in: geometry, includeDivisions: false)
    }
}

extension EnvironmentValues {
    @Entry var remoteContentRespectsContainer = false
    @Entry var remoteContentOverlayBottomInset: CGFloat = 0
    @Entry var remoteContentFittingSize: CGSize? = nil
    @Entry var foldedToolbarUsesControlsPane = true
}
