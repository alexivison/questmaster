import AppKit

final class AttributedText {
    let value = NSMutableAttributedString()
    private let paragraphStyle: NSParagraphStyle?

    init(paragraphStyle: NSParagraphStyle? = nil) {
        self.paragraphStyle = paragraphStyle
    }

    func append(
        _ string: String,
        color: NSColor = AppPalette.text,
        font: NSFont = AppFonts.mono,
        background: NSColor? = nil,
        link: URL? = nil,
        kern: CGFloat? = nil,
        paragraphStyle overrideParagraphStyle: NSParagraphStyle? = nil
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
        if let style = overrideParagraphStyle ?? paragraphStyle {
            attributes[.paragraphStyle] = style
        }
        if let kern {
            attributes[.kern] = kern
        }
        if let background {
            attributes[.backgroundColor] = background
        }
        if let link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        value.append(NSAttributedString(string: string, attributes: attributes))
    }

    func newline(paragraphStyle overrideParagraphStyle: NSParagraphStyle? = nil) {
        append("\n", color: AppPalette.text, paragraphStyle: overrideParagraphStyle)
    }

    func appendSymbol(
        _ name: String,
        fallback: String = "",
        color: NSColor,
        pointSize: CGFloat = AppSymbolStyle.pointSize,
        weight: NSFont.Weight = AppSymbolStyle.weight,
        baselineFont: NSFont = AppFonts.monoSmall
    ) {
        guard let image = AppSymbolStyle.image(name: name, pointSize: pointSize, weight: weight, color: color) else {
            if !fallback.isEmpty {
                append(fallback, color: color, font: baselineFont)
            }
            return
        }

        appendImage(AppSymbolStyle.alignmentCenteredImage(image), baselineFont: baselineFont)
    }

    func appendImage(_ image: NSImage, baselineFont: NSFont) {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = Self.attachmentBounds(size: image.size, baselineFont: baselineFont)
        let rendered = NSMutableAttributedString(attachment: attachment)
        rendered.addAttribute(.font, value: baselineFont, range: NSRange(location: 0, length: rendered.length))
        if let paragraphStyle {
            rendered.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: rendered.length))
        }
        value.append(rendered)
    }

    static func attachmentBounds(size: NSSize, baselineFont: NSFont) -> NSRect {
        NSRect(
            x: 0,
            y: attachmentVerticalOffset(height: size.height, baselineFont: baselineFont),
            width: size.width,
            height: size.height
        )
    }

    static func attachmentVerticalOffset(height: CGFloat, baselineFont: NSFont) -> CGFloat {
        (baselineFont.ascender + baselineFont.descender - height) / 2
    }
}

enum AppSymbolStyle {
    static let pointSize: CGFloat = 12
    static let weight: NSFont.Weight = .regular

    static func image(
        name: String,
        pointSize: CGFloat = AppSymbolStyle.pointSize,
        weight: NSFont.Weight = AppSymbolStyle.weight,
        color: NSColor
    ) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else {
            return nil
        }
        let rect = NSRect(origin: .zero, size: base.size)
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        tinted.alignmentRect = base.alignmentRect
        return tinted
    }

    static func alignmentCenteredImage(_ image: NSImage) -> NSImage {
        let alignmentRect = image.alignmentRect
        guard alignmentRect.width > 0, alignmentRect.height > 0 else {
            return image
        }
        let offset = NSPoint(
            x: (image.size.width / 2) - alignmentRect.midX,
            y: (image.size.height / 2) - alignmentRect.midY
        )
        guard abs(offset.x) > 0.001 || abs(offset.y) > 0.001 else {
            return image
        }

        let centered = NSImage(size: image.size)
        centered.lockFocus()
        image.draw(
            in: NSRect(origin: offset, size: image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        centered.unlockFocus()
        centered.isTemplate = image.isTemplate
        centered.alignmentRect = NSRect(origin: .zero, size: centered.size)
        return centered
    }
}
