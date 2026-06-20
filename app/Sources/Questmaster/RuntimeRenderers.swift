import AppKit

final class AttributedText {
    let value = NSMutableAttributedString()

    func append(
        _ string: String,
        color: NSColor = AppPalette.text,
        font: NSFont = AppFonts.mono,
        background: NSColor? = nil,
        link: URL? = nil
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
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
}
