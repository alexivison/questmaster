import AppKit
import SwiftUI

/// Text whose first baseline sits `baseline` below the top of its frame.
struct BaselineText: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let baseline: CGFloat

    init(_ text: String, font: NSFont, color: NSColor, baseline: CGFloat) {
        self.text = text
        self.font = font
        self.color = color
        self.baseline = baseline
    }

    var body: some View {
        Text(text)
            .font(font.swiftUI)
            .foregroundStyle(color.swiftUI)
            .alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
