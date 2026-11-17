import AppKit
import SwiftUI

/// The header every dock and modal panel shares: `PanelTitle`, then whatever sits under the title as part of the panel's
/// chrome (a dock's Session/All tabs and filter, its Action chips, a modal's chapter rule). The panel's content sits under
/// that. Three gaps, all in `PanelHeaderMetrics`:
///
/// - the title's text frame to the next element's outer edge, and between two elements of one header: `elementGap`;
/// - the header's last element to the panel's content: `contentGap`;
/// - a dock's top bar is `barHeight` tall, so its title's text frame ends `elementGap` above the bar's bottom edge, and the
///   first element under the title sits on that edge. The title's baseline is the one that makes that frame, so the bar,
///   its icons and the close button keep their place.
enum PanelHeaderMetrics {
    static let barHeight = ControlHeight.bar
    static let elementGap = Space.item
    static let contentGap = Space.section
    /// How far the title font's text frame runs below its baseline.
    private static let titleDescent = -AppFonts.panelTitle.descender
    /// The title's baseline, from the panel's top edge.
    static let titleBaseline = barHeight - elementGap - titleDescent
    /// The title's text frame, from the panel's top edge down: the frame a header's elements are measured from.
    static let titleRowHeight = barHeight - elementGap
    /// A dock body's top inset below its bar when nothing sits under the title: the bar already gives `elementGap`, so the
    /// content lands `contentGap` under the title's text frame.
    static let bodyTopInset = contentGap - elementGap
}

/// A panel's title: `AppFonts.panelTitle`, centred across the width it is given, in `color` (the accent, or a destructive
/// sheet's red). Its baseline is `PanelHeaderMetrics.titleBaseline` below the top of the frame it is given.
struct PanelTitle: View {
    let text: String
    var color: NSColor = AppPalette.accent

    var body: some View {
        BaselineText(text, font: AppFonts.panelTitle, color: color, baseline: PanelHeaderMetrics.titleBaseline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }
}
