#!/usr/bin/env swift
import AppKit
import Foundation

struct IconSpec {
    let name: String
    let pixels: CGFloat
}

let specs = [
    IconSpec(name: "icon_16x16.png", pixels: 16),
    IconSpec(name: "icon_16x16@2x.png", pixels: 32),
    IconSpec(name: "icon_32x32.png", pixels: 32),
    IconSpec(name: "icon_32x32@2x.png", pixels: 64),
    IconSpec(name: "icon_128x128.png", pixels: 128),
    IconSpec(name: "icon_128x128@2x.png", pixels: 256),
    IconSpec(name: "icon_256x256.png", pixels: 256),
    IconSpec(name: "icon_256x256@2x.png", pixels: 512),
    IconSpec(name: "icon_512x512.png", pixels: 512),
    IconSpec(name: "icon_512x512@2x.png", pixels: 1024)
]

func usage() -> Never {
    fputs("Usage: generate-app-icon.swift OUTPUT.icns\n", stderr)
    exit(64)
}

guard CommandLine.arguments.count == 2 else { usage() }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let tempIconset = fileManager.temporaryDirectory.appendingPathComponent("CodexPetLimitRings-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: tempIconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: tempIconset) }
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func drawArc(center: CGPoint, radius: CGFloat, width: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool, color: NSColor, glow: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    path.lineWidth = width
    path.lineCapStyle = .round

    if glow > 0 {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = glow
        shadow.shadowColor = color.withAlphaComponent(0.62)
        shadow.shadowOffset = .zero
        shadow.set()
        color.withAlphaComponent(0.42).setStroke()
        path.lineWidth = width * 1.9
        path.stroke()
        NSShadow().set()
        path.lineWidth = width
    }

    color.setStroke()
    path.stroke()
}

func drawIcon(size: CGFloat, destination: URL) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        throw NSError(domain: "CodexPetLimitRingsIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "No graphics context"])
    }
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let rect = CGRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84)
    let corner = size * 0.20
    let background = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        color(0.025, 0.030, 0.045, 1.0),
        color(0.070, 0.085, 0.125, 1.0)
    ])!
    gradient.draw(in: background, angle: -38)

    let bgStroke = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.018, dy: size * 0.018), xRadius: corner * 0.86, yRadius: corner * 0.86)
    color(1.0, 1.0, 1.0, 0.08).setStroke()
    bgStroke.lineWidth = max(1.0, size * 0.008)
    bgStroke.stroke()

    let center = CGPoint(x: size * 0.5, y: size * 0.50)
    drawArc(
        center: center,
        radius: size * 0.315,
        width: max(2.2, size * 0.070),
        start: 92,
        end: -205,
        clockwise: true,
        color: color(0.17, 0.96, 0.80, 0.98),
        glow: size * 0.040
    )
    drawArc(
        center: center,
        radius: size * 0.205,
        width: max(1.8, size * 0.047),
        start: 92,
        end: -88,
        clockwise: true,
        color: color(0.42, 0.73, 1.0, 0.96),
        glow: size * 0.032
    )

    let badge = CGRect(x: size * 0.32, y: size * 0.35, width: size * 0.36, height: size * 0.30)
    let badgePath = NSBezierPath(roundedRect: badge, xRadius: size * 0.065, yRadius: size * 0.065)
    let badgeShadow = NSShadow()
    badgeShadow.shadowBlurRadius = size * 0.035
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    badgeShadow.shadowOffset = .zero
    badgeShadow.set()
    color(0.018, 0.024, 0.034, 0.80).setFill()
    badgePath.fill()
    NSShadow().set()

    let primaryBar = NSBezierPath(roundedRect: CGRect(x: size * 0.37, y: size * 0.525, width: size * 0.26, height: max(1.5, size * 0.030)), xRadius: size * 0.015, yRadius: size * 0.015)
    color(0.17, 0.96, 0.80, 0.98).setFill()
    primaryBar.fill()

    let secondaryBar = NSBezierPath(roundedRect: CGRect(x: size * 0.40, y: size * 0.440, width: size * 0.20, height: max(1.2, size * 0.022)), xRadius: size * 0.011, yRadius: size * 0.011)
    color(0.42, 0.73, 1.0, 0.94).setFill()
    secondaryBar.fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexPetLimitRingsIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try png.write(to: destination)
}

for spec in specs {
    try drawIcon(size: spec.pixels, destination: tempIconset.appendingPathComponent(spec.name))
}

if fileManager.fileExists(atPath: outputURL.path) {
    try fileManager.removeItem(at: outputURL)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", outputURL.path, tempIconset.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "CodexPetLimitRingsIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
