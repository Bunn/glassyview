import AppKit

// Finder uses the TIFF's 1x and 2x representations for a crisp installation
// window on both standard and Retina displays. All positions are in points.
// The extra wash below the instructions also accommodates Finder's optional
// path and status bars without clipping the installation steps.
let canvas = NSSize(width: 700, height: 520)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

let ink = color(0.10, 0.18, 0.30)
let muted = color(0.32, 0.41, 0.54)
let blue = color(0.10, 0.40, 0.91)

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas.height - y - height, width: width, height: height)
}

func rounded(_ bounds: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, foreground: NSColor = ink) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    (string as NSString).draw(in: rect(x, y, width, size * 1.5), withAttributes: [
        .font: NSFont(descriptor: descriptor, size: size) ?? font,
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
    ])
}

func drawBackground() {
    NSGradient(colors: [color(0.975, 0.988, 1), color(0.88, 0.935, 0.995)])!
        .draw(in: NSRect(origin: .zero, size: canvas), angle: -35)

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).addClip()
    let glow = NSGradient(starting: color(0.48, 0.73, 1, 0.22), ending: color(0.48, 0.73, 1, 0))!
    glow.draw(fromCenter: NSPoint(x: 650, y: 420), radius: 0,
              toCenter: NSPoint(x: 650, y: 420), radius: 280, options: [])
    rounded(rect(584, 22, 165, 104), radius: 24,
            fill: color(1, 1, 1, 0.12), stroke: color(0.38, 0.63, 0.98, 0.09))
    rounded(rect(558, 40, 165, 104), radius: 24,
            fill: color(1, 1, 1, 0.10), stroke: color(0.38, 0.63, 0.98, 0.12))
    NSGraphicsContext.restoreGraphicsState()

    rounded(rect(44, 34, 25, 18), radius: 5,
            fill: color(0.38, 0.66, 1, 0.14), stroke: color(0.10, 0.40, 0.91, 0.58))
    rounded(rect(38, 40, 25, 18), radius: 5,
            fill: color(0.38, 0.66, 1, 0.18), stroke: color(0.10, 0.40, 0.91, 0.72))
    text("Glassy Desk", x: 80, y: 34, width: 300, size: 17, weight: .semibold)
    text("Your Mac. A tap away.", x: 38, y: 85, width: 624, size: 35, weight: .semibold)
    text("Drag Glassy Desk to Applications to get started.",
         x: 40, y: 137, width: 620, size: 15, foreground: muted)

    for x: CGFloat in [68, 422] {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0.21, 0.42, 0.72, 0.08)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        rounded(rect(x, 188, 210, 160), radius: 28, fill: color(1, 1, 1, 0.54))
        NSGraphicsContext.restoreGraphicsState()
        rounded(rect(x, 188, 210, 160), radius: 28,
                fill: .clear, stroke: color(1, 1, 1, 0.85))
    }

    // A quiet directional cue; the actual app and folder remain Finder icons.
    rounded(rect(322, 228, 56, 56), radius: 28, fill: color(1, 1, 1, 0.60))
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 336, y: canvas.height - 256))
    arrow.line(to: NSPoint(x: 364, y: canvas.height - 256))
    arrow.move(to: NSPoint(x: 356, y: canvas.height - 247))
    arrow.line(to: NSPoint(x: 365, y: canvas.height - 256))
    arrow.line(to: NSPoint(x: 356, y: canvas.height - 265))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    blue.setStroke()
    arrow.stroke()

    rounded(rect(68, 381, 564, 54), radius: 16, fill: color(1, 1, 1, 0.46))
    rounded(rect(83, 396, 24, 24), radius: 12, fill: color(0.10, 0.40, 0.91, 0.10))
    text("2", x: 91, y: 398, width: 18, size: 13, weight: .semibold, foreground: blue)
    text("Open Glassy Desk from Applications", x: 119, y: 389, width: 500,
         size: 13, weight: .semibold)
    text("We’ll guide you through permissions and pairing.", x: 119, y: 409,
         width: 500, size: 12, foreground: muted)
}

var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale,
        pixelsHigh: Int(canvas.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()
    representations.append(bitmap)
}
let tiff = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff, properties: [:])!
try tiff.write(to: output.appendingPathComponent("background.tiff"))
try representations[1].representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("background@2x.png"))
