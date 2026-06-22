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
        kern: CGFloat? = nil
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
        if let paragraphStyle {
            attributes[.paragraphStyle] = paragraphStyle
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

    func newline() {
        append("\n", color: AppPalette.text)
    }

    func appendSymbol(
        _ name: String,
        fallback: String = "",
        color: NSColor,
        pointSize: CGFloat = AppSymbolStyle.pointSize,
        weight: NSFont.Weight = AppSymbolStyle.weight
    ) {
        guard let image = AppSymbolStyle.image(name: name, pointSize: pointSize, weight: weight, color: color) else {
            if !fallback.isEmpty {
                append(fallback, color: color, font: AppFonts.monoSmall)
            }
            return
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        let rendered = NSMutableAttributedString(attachment: attachment)
        if let paragraphStyle {
            rendered.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: rendered.length))
        }
        value.append(rendered)
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
        return tinted
    }
}
