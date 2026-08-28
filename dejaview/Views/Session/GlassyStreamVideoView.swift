import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI surface for ``GlassyStreamVideoRenderer``. The backing
/// `AVSampleBufferDisplayLayer` performs hardware H.264 decode and preserves
/// the remote display's aspect ratio with letterboxing as needed.
struct GlassyStreamVideoView: UIViewRepresentable {
    let renderer: GlassyStreamVideoRenderer

    func makeUIView(context: Context) -> GlassyStreamDisplayView {
        let view = GlassyStreamDisplayView()
        view.attach(renderer)
        return view
    }

    func updateUIView(_ uiView: GlassyStreamDisplayView, context: Context) {
        uiView.attach(renderer)
    }

    static func dismantleUIView(_ uiView: GlassyStreamDisplayView, coordinator: Void) {
        uiView.detachRenderer()
    }
}

final class GlassyStreamDisplayView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private weak var attachedRenderer: GlassyStreamVideoRenderer?

    private var videoLayer: AVSampleBufferDisplayLayer {
        guard let videoLayer = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("GlassyStreamDisplayView requires AVSampleBufferDisplayLayer")
        }
        return videoLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        isOpaque = true
        backgroundColor = .black
        clipsToBounds = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ renderer: GlassyStreamVideoRenderer) {
        guard attachedRenderer !== renderer else { return }

        attachedRenderer?.detach(from: videoLayer)
        attachedRenderer = renderer
        renderer.attach(to: videoLayer)
    }

    func detachRenderer() {
        attachedRenderer?.detach(from: videoLayer)
        attachedRenderer = nil
    }
}
