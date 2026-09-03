import AppKit
import CoreImage.CIFilterBuiltins
import Vision

/// Produces a camera-readable 300-point QR image on an opaque white surface.
/// Rounded modules, finder eyes, and the center display mark are drawn as vectors
/// at an integer module scale. Every image keeps a four-module quiet zone.
enum HostPairingQRCode {
    static let displaySize: CGFloat = 300
    private static let quietZone = 4
    private static let pixelsPerModule = 10

    /// Returns an image only after Vision decodes the exact input at its display
    /// size. If decoration interferes, progressively simpler renderings are tried.
    /// Payloads are neither logged nor persisted.
    static func image(for payload: String) -> NSImage? {
        guard let matrix = makeMatrix(for: payload) else { return nil }
        for style in [Style.marked, .rounded, .standard] {
            guard let rendered = render(matrix, style: style),
                  canDecode(rendered, as: payload) else { continue }
            return NSImage(
                cgImage: rendered,
                size: NSSize(width: displaySize, height: displaySize)
            )
        }
        return nil
    }

    private enum Style {
        case marked, rounded, standard
    }

    private struct Matrix {
        let side: Int
        let modules: [Bool]

        func isDark(x: Int, y: Int) -> Bool { modules[y * side + x] }

        var finderOrigins: [(x: Int, y: Int)] {
            [(0, 0), (side - 7, 0), (0, side - 7), (side - 7, side - 7)]
                .filter { origin in
                    // Inspect the original matrix so Core Image's raster
                    // orientation cannot move a finder eye to the wrong corner.
                    (0..<7).allSatisfy { y in
                        (0..<7).allSatisfy { x in
                            let border = x == 0 || x == 6 || y == 0 || y == 6
                            let center = (2...4).contains(x) && (2...4).contains(y)
                            return isDark(x: origin.0 + x, y: origin.1 + y)
                                == (border || center)
                        }
                    }
                }
        }
    }

    private static func makeMatrix(for payload: String) -> Matrix? {
        guard !payload.isEmpty, payload.utf8.count <= 2_048 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let side = Int(output.extent.width)
        guard side > 0, side == Int(output.extent.height) else { return nil }
        guard let sourceImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        var pixels = [UInt8](repeating: 255, count: side * side)
        let didRender = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard didRender else { return nil }

        // Core Image supplies a small border. Find the actual symbol's extent
        // and replace that border with exactly four light modules on every edge.
        var minimumX = side
        var minimumY = side
        var maximumX = 0
        var maximumY = 0
        for y in 0..<side {
            for x in 0..<side where pixels[y * side + x] < 128 {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        let symbolSide = maximumX - minimumX + 1
        guard symbolSide >= 21, symbolSide == maximumY - minimumY + 1 else { return nil }
        var modules: [Bool] = []
        modules.reserveCapacity(symbolSide * symbolSide)
        for y in minimumY...maximumY {
            for x in minimumX...maximumX {
                modules.append(pixels[y * side + x] < 128)
            }
        }
        return Matrix(side: symbolSide, modules: modules)
    }

    private static func render(_ matrix: Matrix, style: Style) -> CGImage? {
        let module = CGFloat(pixelsPerModule)
        let pixelSide = (matrix.side + quietZone * 2) * pixelsPerModule
        guard let context = makeContext(side: pixelSide) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setShouldAntialias(style != .standard)

        let finderOrigins = matrix.finderOrigins
        for y in 0..<matrix.side {
            for x in 0..<matrix.side where matrix.isDark(x: x, y: y) {
                if style != .standard && finderOrigins.contains(where: {
                    ($0.x..<$0.x + 7).contains(x) && ($0.y..<$0.y + 7).contains(y)
                }) { continue }
                let rect = CGRect(
                    x: CGFloat(x + quietZone) * module,
                    y: CGFloat(matrix.side - y - 1 + quietZone) * module,
                    width: module,
                    height: module
                )
                if style == .standard {
                    context.fill(rect)
                } else {
                    let inset = rect.insetBy(dx: module * 0.055, dy: module * 0.055)
                    context.addPath(CGPath(
                        roundedRect: inset,
                        cornerWidth: module * 0.36,
                        cornerHeight: module * 0.36,
                        transform: nil
                    ))
                    context.fillPath()
                }
            }
        }

        if style != .standard {
            for origin in finderOrigins {
                let rect = CGRect(
                    x: CGFloat(origin.x + quietZone) * module,
                    y: CGFloat(matrix.side - origin.y - 7 + quietZone) * module,
                    width: 7 * module,
                    height: 7 * module
                )
                fillRounded(rect, radius: 1.55 * module, gray: 0, in: context)
                fillRounded(rect.insetBy(dx: module, dy: module), radius: 0.65 * module, gray: 1, in: context)
                fillRounded(rect.insetBy(dx: 2 * module, dy: 2 * module), radius: 0.65 * module, gray: 0, in: context)
            }
        }
        if style == .marked {
            drawDisplayMark(center: CGPoint(x: bounds.midX, y: bounds.midY), module: module, in: context)
        }
        return context.makeImage()
    }

    private static func drawDisplayMark(center: CGPoint, module: CGFloat, in context: CGContext) {
        let badge = CGRect(
            x: center.x - module * 4,
            y: center.y - module * 4,
            width: module * 8,
            height: module * 8
        )
        fillRounded(badge, radius: module * 2.1, gray: 1, in: context)
        let screen = CGRect(
            x: center.x - module * 2.2,
            y: center.y - module * 0.7,
            width: module * 4.4,
            height: module * 3.2
        )
        fillRounded(screen, radius: module * 0.7, gray: 0, in: context)
        fillRounded(screen.insetBy(dx: module * 0.45, dy: module * 0.45), radius: module * 0.25, gray: 1, in: context)
        fillRounded(
            CGRect(x: center.x - module * 0.3, y: center.y - module * 1.8, width: module * 0.6, height: module * 1.3),
            radius: module * 0.2, gray: 0, in: context
        )
        fillRounded(
            CGRect(x: center.x - module * 1.25, y: center.y - module * 2.15, width: module * 2.5, height: module * 0.5),
            radius: module * 0.25, gray: 0, in: context
        )
    }

    private static func fillRounded(_ rect: CGRect, radius: CGFloat, gray: CGFloat, in context: CGContext) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func makeContext(side: Int) -> CGContext? {
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    private static func canDecode(_ image: CGImage, as payload: String) -> Bool {
        guard let context = makeContext(side: Int(displaySize)) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: displaySize, height: displaySize))
        guard let displayImage = context.makeImage() else { return false }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: displayImage).perform([request])
            return request.results?.contains(where: { $0.payloadStringValue == payload }) == true
        } catch {
            return false
        }
    }
}
