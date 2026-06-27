// Render the app icon PNG with a transparent rounded mask.
// The source artwork is a full square illustration; Dock/Finder custom icons
// need transparent corners, otherwise macOS shows a visible black square.
import AppKit

let inputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/AppIcon-1024.png"
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "scripts/AppIcon-1024.png"

let size = 1024
let canvas = NSSize(width: size, height: size)
guard let source = NSImage(contentsOfFile: inputPath) else {
    fputs("Unable to read icon source: \(inputPath)\n", stderr)
    exit(1)
}
source.size = canvas

guard let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Unable to decode icon source\n", stderr)
    exit(2)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Unable to create icon graphics context\n", stderr)
    exit(3)
}

let bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
context.clear(bounds)

let inset: CGFloat = 42
let iconRect = bounds.insetBy(dx: inset, dy: inset)
let cornerRadius: CGFloat = 206
context.addPath(CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
context.clip()
context.interpolationQuality = .high
context.draw(sourceImage, in: bounds)

guard let renderedImage = context.makeImage() else {
    fputs("Unable to render icon image\n", stderr)
    exit(4)
}

let rep = NSBitmapImageRep(cgImage: renderedImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG\n", stderr)
    exit(5)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("Unable to write icon PNG: \(error)\n", stderr)
    exit(6)
}
