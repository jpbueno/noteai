#!/usr/bin/swift

import AppKit
import CoreGraphics

let s: CGFloat = 512
let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("icon_previews").path
let colorSpace = CGColorSpaceCreateDeviceRGB()

func save(_ image: NSImage, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

func roundedBG(_ ctx: CGContext, color1: CGColor, color2: CGColor, color3: CGColor? = nil) {
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.20, cornerHeight: s * 0.20, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    var colors = [color1, color2]
    var locs: [CGFloat] = [0.0, 1.0]
    if let c3 = color3 { colors.append(c3); locs = [0.0, 0.5, 1.0] }
    if let g = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locs) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
}

func drawText(_ ctx: CGContext, text: String, fontSize: CGFloat, x: CGFloat, y: CGFloat, color: NSColor, weight: NSFont.Weight = .bold, design: NSFontDescriptor.SystemDesign = .rounded) {
    let baseFont = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let descriptor = baseFont.fontDescriptor.withDesign(design) ?? baseFont.fontDescriptor
    let font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    str.draw(at: NSPoint(x: x, y: y))
}

func drawBrain(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, scale: CGFloat, fillColor: CGColor, foldColor: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    let r = scale

    // Full brain outline
    let brain = CGMutablePath()
    brain.move(to: CGPoint(x: 0, y: -r * 0.90))
    // Top curve
    brain.addCurve(to: CGPoint(x: -r * 0.80, y: -r * 0.30), control1: CGPoint(x: -r * 0.50, y: -r * 0.95), control2: CGPoint(x: -r * 0.90, y: -r * 0.65))
    // Left bulge
    brain.addCurve(to: CGPoint(x: -r * 0.75, y: r * 0.25), control1: CGPoint(x: -r * 1.0, y: -r * 0.05), control2: CGPoint(x: -r * 0.95, y: r * 0.15))
    // Bottom left
    brain.addCurve(to: CGPoint(x: -r * 0.25, y: r * 0.70), control1: CGPoint(x: -r * 0.60, y: r * 0.50), control2: CGPoint(x: -r * 0.40, y: r * 0.65))
    // Bottom center
    brain.addCurve(to: CGPoint(x: r * 0.25, y: r * 0.70), control1: CGPoint(x: -r * 0.10, y: r * 0.78), control2: CGPoint(x: r * 0.10, y: r * 0.78))
    // Bottom right
    brain.addCurve(to: CGPoint(x: r * 0.75, y: r * 0.25), control1: CGPoint(x: r * 0.40, y: r * 0.65), control2: CGPoint(x: r * 0.60, y: r * 0.50))
    // Right bulge
    brain.addCurve(to: CGPoint(x: r * 0.80, y: -r * 0.30), control1: CGPoint(x: r * 0.95, y: r * 0.15), control2: CGPoint(x: r * 1.0, y: -r * 0.05))
    // Top right
    brain.addCurve(to: CGPoint(x: 0, y: -r * 0.90), control1: CGPoint(x: r * 0.90, y: -r * 0.65), control2: CGPoint(x: r * 0.50, y: -r * 0.95))
    brain.closeSubpath()

    ctx.setFillColor(fillColor)
    ctx.addPath(brain)
    ctx.fillPath()

    // Brain folds
    ctx.setStrokeColor(foldColor)
    ctx.setLineWidth(s * 0.007)
    ctx.setLineCap(.round)

    // Left folds
    let folds: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: -r*0.60, y: -r*0.10), CGPoint(x: -r*0.40, y: -r*0.25), CGPoint(x: -r*0.20, y: -r*0.30), CGPoint(x: -r*0.05, y: -r*0.20)),
        (CGPoint(x: -r*0.65, y: r*0.15), CGPoint(x: -r*0.45, y: r*0.05), CGPoint(x: -r*0.25, y: r*0.00), CGPoint(x: -r*0.05, y: r*0.05)),
        (CGPoint(x: -r*0.45, y: r*0.40), CGPoint(x: -r*0.30, y: r*0.30), CGPoint(x: -r*0.15, y: r*0.25), CGPoint(x: -r*0.05, y: r*0.30)),
        (CGPoint(x: r*0.60, y: -r*0.10), CGPoint(x: r*0.40, y: -r*0.25), CGPoint(x: r*0.20, y: -r*0.30), CGPoint(x: r*0.05, y: -r*0.20)),
        (CGPoint(x: r*0.65, y: r*0.15), CGPoint(x: r*0.45, y: r*0.05), CGPoint(x: r*0.25, y: r*0.00), CGPoint(x: r*0.05, y: r*0.05)),
        (CGPoint(x: r*0.45, y: r*0.40), CGPoint(x: r*0.30, y: r*0.30), CGPoint(x: r*0.15, y: r*0.25), CGPoint(x: r*0.05, y: r*0.30)),
    ]
    for f in folds {
        ctx.move(to: f.0)
        ctx.addCurve(to: f.3, control1: f.1, control2: f.2)
        ctx.strokePath()
    }

    // Center line
    ctx.setLineWidth(s * 0.005)
    ctx.move(to: CGPoint(x: 0, y: -r * 0.85))
    ctx.addLine(to: CGPoint(x: 0, y: r * 0.65))
    ctx.strokePath()

    ctx.restoreGState()
}

// ===== OPTION 1: Minimal black N + small brain badge =====
func option1() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 1, green: 1, blue: 1, alpha: 1), color2: CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    drawText(ctx, text: "N", fontSize: s * 0.65, x: s * 0.12, y: s * 0.15, color: NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), weight: .black, design: .default)
    drawBrain(ctx, cx: s * 0.75, cy: s * 0.72, scale: s * 0.13, fillColor: CGColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 1), foldColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
    img.unlockFocus()
    return img
}

// ===== OPTION 2: Gradient purple-blue BG, white N + brain =====
func option2() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.35, green: 0.20, blue: 0.85, alpha: 1), color2: CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1))
    drawText(ctx, text: "N", fontSize: s * 0.55, x: s * 0.08, y: s * 0.12, color: .white, weight: .heavy, design: .rounded)
    drawBrain(ctx, cx: s * 0.72, cy: s * 0.68, scale: s * 0.15, fillColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.95), foldColor: CGColor(red: 0.30, green: 0.20, blue: 0.80, alpha: 0.4))
    img.unlockFocus()
    return img
}

// ===== OPTION 3: Dark slate, green accent brain =====
func option3() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1), color2: CGColor(red: 0.15, green: 0.17, blue: 0.20, alpha: 1))
    drawText(ctx, text: "N", fontSize: s * 0.60, x: s * 0.10, y: s * 0.14, color: .white, weight: .black, design: .default)
    drawBrain(ctx, cx: s * 0.73, cy: s * 0.70, scale: s * 0.14, fillColor: CGColor(red: 0.18, green: 0.82, blue: 0.55, alpha: 1), foldColor: CGColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.45))
    img.unlockFocus()
    return img
}

// ===== OPTION 4: Black bg, centered large brain with "N" overlaid =====
func option4() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1), color2: CGColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 1))
    drawBrain(ctx, cx: s * 0.50, cy: s * 0.52, scale: s * 0.28, fillColor: CGColor(red: 0.25, green: 0.50, blue: 1.0, alpha: 0.25), foldColor: CGColor(red: 0.35, green: 0.60, blue: 1.0, alpha: 0.5))
    drawText(ctx, text: "N", fontSize: s * 0.50, x: s * 0.18, y: s * 0.17, color: NSColor(white: 1, alpha: 0.95), weight: .black, design: .rounded)
    img.unlockFocus()
    return img
}

// ===== OPTION 5: Coral/orange gradient, white N + brain =====
func option5() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 1.0, green: 0.40, blue: 0.30, alpha: 1), color2: CGColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1))
    drawText(ctx, text: "N", fontSize: s * 0.55, x: s * 0.08, y: s * 0.12, color: .white, weight: .heavy, design: .rounded)
    drawBrain(ctx, cx: s * 0.72, cy: s * 0.68, scale: s * 0.15, fillColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.95), foldColor: CGColor(red: 0.90, green: 0.30, blue: 0.20, alpha: 0.4))
    img.unlockFocus()
    return img
}

// ===== OPTION 6: White bg, brain IS the N (brain shaped with N cutout) =====
func option6() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1), color2: CGColor(red: 0.94, green: 0.94, blue: 0.98, alpha: 1))
    // Large centered brain
    drawBrain(ctx, cx: s * 0.50, cy: s * 0.50, scale: s * 0.30, fillColor: CGColor(red: 0.22, green: 0.22, blue: 0.28, alpha: 1), foldColor: CGColor(red: 0.94, green: 0.94, blue: 0.98, alpha: 0.35))
    // "N" text below
    drawText(ctx, text: "NoteAI", fontSize: s * 0.09, x: s * 0.24, y: s * 0.08, color: NSColor(red: 0.22, green: 0.22, blue: 0.28, alpha: 0.8), weight: .semibold, design: .rounded)
    img.unlockFocus()
    return img
}

// ===== OPTION 7: Notion-exact style — cream bg, serif N, tiny brain =====
func option7() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 1), color2: CGColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1))
    // Border
    let borderRect = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s*0.004, dy: s*0.004)
    let borderPath = CGPath(roundedRect: borderRect, cornerWidth: s*0.20, cornerHeight: s*0.20, transform: nil)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.06))
    ctx.setLineWidth(s * 0.004)
    ctx.addPath(borderPath)
    ctx.strokePath()
    // Large centered N in serif
    let font = NSFont(name: "Georgia-Bold", size: s * 0.62) ?? NSFont.systemFont(ofSize: s * 0.62, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)]
    NSAttributedString(string: "N", attributes: attrs).draw(at: NSPoint(x: s * 0.15, y: s * 0.14))
    // Small brain top-right
    drawBrain(ctx, cx: s * 0.78, cy: s * 0.78, scale: s * 0.10, fillColor: CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1), foldColor: CGColor(red: 1, green: 0.99, blue: 0.96, alpha: 0.4))
    img.unlockFocus()
    return img
}

// ===== OPTION 8: Teal gradient, bold rounded N + brain =====
func option8() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.05, green: 0.75, blue: 0.70, alpha: 1), color2: CGColor(red: 0.10, green: 0.55, blue: 0.80, alpha: 1))
    drawText(ctx, text: "N", fontSize: s * 0.55, x: s * 0.08, y: s * 0.12, color: .white, weight: .black, design: .rounded)
    drawBrain(ctx, cx: s * 0.72, cy: s * 0.68, scale: s * 0.15, fillColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.95), foldColor: CGColor(red: 0.05, green: 0.55, blue: 0.60, alpha: 0.4))
    img.unlockFocus()
    return img
}

// ===== OPTION 9: Deep navy, neon blue brain + white N =====
func option9() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.06, green: 0.07, blue: 0.15, alpha: 1), color2: CGColor(red: 0.08, green: 0.10, blue: 0.22, alpha: 1))
    // Brain glow
    let glowC = [CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.15), CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0)]
    if let g = CGGradient(colorsSpace: colorSpace, colors: glowC as CFArray, locations: [0,1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: s*0.72, y: s*0.68), startRadius: 0, endCenter: CGPoint(x: s*0.72, y: s*0.68), endRadius: s*0.25, options: [])
    }
    drawText(ctx, text: "N", fontSize: s * 0.58, x: s * 0.08, y: s * 0.12, color: .white, weight: .heavy, design: .rounded)
    drawBrain(ctx, cx: s * 0.72, cy: s * 0.68, scale: s * 0.15, fillColor: CGColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1), foldColor: CGColor(red: 0.06, green: 0.07, blue: 0.15, alpha: 0.4))
    img.unlockFocus()
    return img
}

// ===== OPTION 10: Black bg, large brain center, "N" in brain, gold accents =====
func option10() -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    roundedBG(ctx, color1: CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1), color2: CGColor(red: 0.06, green: 0.05, blue: 0.10, alpha: 1))
    // Gold brain glow
    let glowC = [CGColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 0.12), CGColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 0)]
    if let g = CGGradient(colorsSpace: colorSpace, colors: glowC as CFArray, locations: [0,1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: s*0.5, y: s*0.52), startRadius: 0, endCenter: CGPoint(x: s*0.5, y: s*0.52), endRadius: s*0.38, options: [])
    }
    drawBrain(ctx, cx: s * 0.50, cy: s * 0.52, scale: s * 0.28, fillColor: CGColor(red: 0.85, green: 0.68, blue: 0.25, alpha: 0.9), foldColor: CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 0.4))
    drawText(ctx, text: "N", fontSize: s * 0.32, x: s * 0.30, y: s * 0.28, color: NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 0.85), weight: .black, design: .rounded)
    img.unlockFocus()
    return img
}

save(option1(), name: "option_01")
save(option2(), name: "option_02")
save(option3(), name: "option_03")
save(option4(), name: "option_04")
save(option5(), name: "option_05")
save(option6(), name: "option_06")
save(option7(), name: "option_07")
save(option8(), name: "option_08")
save(option9(), name: "option_09")
save(option10(), name: "option_10")
print("All 10 options generated!")
