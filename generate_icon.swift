#!/usr/bin/swift

import AppKit
import CoreGraphics

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))

    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Add transparent outer inset so the icon's visual weight matches standard macOS app icons.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - (inset * 2), height: s - (inset * 2))
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.20, cornerHeight: rect.height * 0.20, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 0.098, green: 0.098, blue: 0.098, alpha: 1))
    ctx.fill(rect)

    // Draw SF Symbol "brain.head.profile" centered
    let symbolSize = rect.width * 0.55
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
    if let symbolImage = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        let symbolRect = symbolImage.size
        let x = rect.midX - (symbolRect.width / 2)
        let y = rect.midY - (symbolRect.height / 2)

        // Tint gray (#A0A0A0)
        let tinted = NSImage(size: symbolRect, flipped: false) { drawRect in
            NSColor(red: 0.63, green: 0.63, blue: 0.63, alpha: 1).set()
            symbolImage.draw(in: drawRect)
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceIn)
            NSGraphicsContext.current?.cgContext.fill(drawRect)
            return true
        }
        tinted.draw(in: NSRect(x: x, y: y, width: symbolRect.width, height: symbolRect.height))
    }

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let basePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("NoteAI/Assets.xcassets/AppIcon.appiconset").path
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (sz, fn) in sizes {
    savePNG(generateIcon(size: sz), size: sz, to: "\(basePath)/\(fn)")
}
print("Done!")
