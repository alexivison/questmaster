#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize = 1024
private let amber = color("#d8ab5c")
private let offWhite = color("#e7e2d7")
private let nearBlack = color("#121517")
private let panelBlack = color("#1b1f23")

private struct Options {
    let outputDirectory: URL
    let reportsDirectory: URL
    let reportDate: String
}

private enum Variant: String, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"

    var outputName: String {
        "QuestmasterIcon-\(rawValue).png"
    }

    func reportName(date: String) -> String {
        "\(date)-questmaster-icon-\(rawValue).png"
    }
}

private let options = try parseOptions()
try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: options.reportsDirectory, withIntermediateDirectories: true)

for variant in Variant.allCases {
    let representation = render(variant: variant)
    let outputURL = options.outputDirectory.appendingPathComponent(variant.outputName)
    let reportURL = options.reportsDirectory.appendingPathComponent(variant.reportName(date: options.reportDate))
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw IconError(message: "failed to encode \(variant.rawValue)")
    }
    try data.write(to: outputURL, options: .atomic)
    try data.write(to: reportURL, options: .atomic)
    print("\(variant.rawValue) \(outputURL.path) \(reportURL.path)")
}

private func parseOptions() throws -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let output = value(after: "--output", in: arguments) ?? FileManager.default.currentDirectoryPath
    let reports = value(after: "--reports", in: arguments)
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".docs/reports").path
    let date = value(after: "--report-date", in: arguments) ?? isoDate()
    return Options(
        outputDirectory: URL(fileURLWithPath: output, isDirectory: true),
        reportsDirectory: URL(fileURLWithPath: reports, isDirectory: true),
        reportDate: date
    )
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func isoDate() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private func render(variant: Variant) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasSize,
        pixelsHigh: canvasSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("failed to create bitmap representation")
    }
    representation.size = NSSize(width: canvasSize, height: canvasSize)

    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("failed to create graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let rect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    NSColor.clear.setFill()
    rect.fill()
    drawBase(in: rect)

    switch variant {
    case .a:
        drawCenteredGlyph("⚔", font: symbolFont(size: 562), color: amber, yOffset: -12)
    case .b:
        drawCenteredGlyph("Q", font: monoFont(size: 596, weight: .bold), color: offWhite, yOffset: -22)
        drawCursorBlock(rect: NSRect(x: 670, y: 292, width: 104, height: 166), color: amber)
    case .c:
        drawCenteredGlyph("❯", font: symbolFont(size: 486), color: amber, xOffset: -104, yOffset: -6)
        drawCenteredGlyph("▮", font: monoFont(size: 422, weight: .bold), color: offWhite, xOffset: 116, yOffset: -16)
    }

    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func drawBase(in rect: NSRect) {
    let baseRect = rect.insetBy(dx: 54, dy: 54)
    let radius: CGFloat = 206
    let path = NSBezierPath(roundedRect: baseRect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let outerShadow = NSShadow()
    outerShadow.shadowBlurRadius = 46
    outerShadow.shadowOffset = NSSize(width: 0, height: -24)
    outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    outerShadow.set()
    nearBlack.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: panelBlack, ending: nearBlack)
    gradient?.draw(in: path, angle: -72)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    color("#ffffff", alpha: 0.055).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 92, y: 684, width: 840, height: 194),
        xRadius: 98,
        yRadius: 98
    ).fill()
    color("#000000", alpha: 0.12).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 92, y: 92, width: 840, height: 190),
        xRadius: 94,
        yRadius: 94
    ).fill()
    NSGraphicsContext.restoreGraphicsState()

    amber.withAlphaComponent(0.18).setStroke()
    path.lineWidth = 8
    path.stroke()
}

private func drawCenteredGlyph(
    _ glyph: String,
    font: NSFont,
    color: NSColor,
    xOffset: CGFloat = 0,
    yOffset: CGFloat = 0
) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: 0,
        .shadow: shadow,
    ]
    let text = glyph as NSString
    let size = text.size(withAttributes: attributes)
    let point = NSPoint(
        x: CGFloat(canvasSize) / 2 - size.width / 2 + xOffset,
        y: CGFloat(canvasSize) / 2 - size.height / 2 + yOffset
    )
    text.draw(at: point, withAttributes: attributes)
}

private func drawCursorBlock(rect: NSRect, color: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
    let shadow = NSShadow()
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.set()
    color.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

private func symbolFont(size: CGFloat) -> NSFont {
    NSFont(name: "Apple Symbols", size: size)
        ?? NSFont.systemFont(ofSize: size, weight: .semibold)
}

private func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    for name in ["IBM Plex Mono", "IBM Plex Mono SemiBold", "Menlo-Bold", "Menlo"] {
        if let font = NSFont(name: name, size: size) {
            return font
        }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

private func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
    var value = hex
    if value.hasPrefix("#") {
        value.removeFirst()
    }
    var integer: UInt64 = 0
    Scanner(string: value).scanHexInt64(&integer)
    let red = CGFloat((integer >> 16) & 0xff) / 255
    let green = CGFloat((integer >> 8) & 0xff) / 255
    let blue = CGFloat(integer & 0xff) / 255
    return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
}

private struct IconError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
