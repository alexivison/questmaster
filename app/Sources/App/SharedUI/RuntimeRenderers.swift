import AppKit

enum AppSymbolStyle {
    static let pointSize: CGFloat = 12
    static let weight: NSFont.Weight = .regular

    private static let symbolCache = NSCache<NSString, NSImage>()

    static func image(
        name: String,
        pointSize: CGFloat = AppSymbolStyle.pointSize,
        weight: NSFont.Weight = AppSymbolStyle.weight,
        color: NSColor,
        canvasSize: NSSize? = nil
    ) -> NSImage? {
        let cacheKey = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.hashValue)|\(canvasSize?.width ?? -1)x\(canvasSize?.height ?? -1)" as NSString
        if let cached = symbolCache.object(forKey: cacheKey) {
            return cached
        }

        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else {
            return nil
        }

        let size = canvasSize ?? integralSize(base.size)
        let tinted = NSImage(size: size, flipped: false) { rect in
            let scale = currentBackingScale()
            let drawRect = pixelAligned(aspectFitRect(for: base.size, in: rect), scale: scale)
            base.draw(
                in: drawRect,
                from: NSRect(origin: .zero, size: base.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            color.setFill()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.cacheMode = .never
        tinted.alignmentRect = alignmentRect(for: base, in: size)
        symbolCache.setObject(tinted, forKey: cacheKey)
        return tinted
    }

    static func resourceImage(
        name: String,
        fileExtension: String,
        subdirectory: String? = nil,
        canvasSize: NSSize,
        tintColor: NSColor? = nil
    ) -> NSImage? {
        let bundle = appResourceBundle() ?? Bundle.module
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        guard let url,
              let base = NSImage(contentsOf: url) else {
            return nil
        }
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let scale = currentBackingScale()
            let drawRect = pixelAligned(aspectFitRect(for: base.size, in: rect), scale: scale)
            base.draw(
                in: drawRect,
                from: NSRect(origin: .zero, size: base.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            if let tintColor {
                tintColor.setFill()
                drawRect.fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.alignmentRect = NSRect(origin: .zero, size: canvasSize)
        return image
    }

    private static func appResourceBundle() -> Bundle? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        return Bundle(url: resourceURL.appendingPathComponent("Questmaster_Questmaster.bundle"))
    }

    static func glyphImage(
        _ glyph: String,
        font: NSFont,
        color: NSColor,
        canvasSize: NSSize
    ) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let glyphSize = (glyph as NSString).size(withAttributes: attributes)
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let scale = currentBackingScale()
            let drawRect = pixelAligned(
                NSRect(
                    x: rect.midX - glyphSize.width / 2,
                    y: rect.midY - glyphSize.height / 2,
                    width: glyphSize.width,
                    height: glyphSize.height
                ),
                scale: scale
            )
            (glyph as NSString).draw(in: drawRect, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.alignmentRect = NSRect(origin: .zero, size: canvasSize)
        return image
    }

    private static func integralSize(_ size: NSSize) -> NSSize {
        NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func aspectFitRect(for sourceSize: NSSize, in rect: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let size = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func alignmentRect(for image: NSImage, in canvasSize: NSSize) -> NSRect {
        let drawRect = aspectFitRect(
            for: image.size,
            in: NSRect(origin: .zero, size: canvasSize)
        )
        guard image.size.width > 0, image.size.height > 0 else {
            return drawRect
        }
        let scaleX = drawRect.width / image.size.width
        let scaleY = drawRect.height / image.size.height
        return NSRect(
            x: drawRect.minX + image.alignmentRect.minX * scaleX,
            y: drawRect.minY + image.alignmentRect.minY * scaleY,
            width: image.alignmentRect.width * scaleX,
            height: image.alignmentRect.height * scaleY
        )
    }

    private static func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func currentBackingScale() -> CGFloat {
        if let transform = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform {
            let scale = max(abs(transform.a), abs(transform.d))
            if scale > 0 {
                return scale
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }
}
