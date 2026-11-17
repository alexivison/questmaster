import AppKit
import QuestmasterCore
import SwiftUI

/// The dock's title plate (the title tab): a nameplate whose centre sits on each dock panel's top border, so it breaks the
/// border and hides it behind its panel fill. Its ends are `AngledButtonShape`, the angled buttons' own, and its
/// 2pt border lifts to `controlBorder` with the panel's frame while the dock has the keys. While a refresh the user asked for
/// runs, it takes the on look (`OnLook`): the brass glow band inside its border and the spinner round it.
enum DockTitlePlateMetrics {
    static let height: CGFloat = 30
    /// How far the plate rises above the panel's top edge. The panel's border lies inside its outline, so its centre line is
    /// `ScoopedRectangle.borderWidth / 2` below the edge, and the plate's centre sits `height / 2 - lift` below the edge. Setting
    /// the two equal gives `lift = height / 2 - borderWidth / 2`: 14 for this 30pt plate and the 2pt border.
    static let lift = height / 2 - ScoopedRectangle.borderWidth / 2
    /// The plate's padding either side of the title.
    static let titleInset = Space.section
    /// The plate's border, 2pt inside its outline: a stroke twice as wide, clipped to the shape.
    static let borderWidth = Token.Size.hairline
    static let borderStrokeWidth = 2 * borderWidth
    /// The glow band's width from the outline: past the border, so the band shows inside it.
    static let glowBand = borderWidth + Token.Size.glowRing
}

/// The title on its plate. The glow and the spinner come from the shared on look, drawn with the plate's own outline.
struct DockTitlePlateView: View {
    let model: DockChromeModel

    var body: some View {
        if let title = model.topBar.title {
            let shape = AngledButtonShape()
            let look = OnLook.of(model.isRefreshing())
            Text(title)
                .font(AppFonts.dockTopBarTitle.swiftUI)
                .foregroundStyle(AppPalette.accent.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, DockTitlePlateMetrics.titleInset)
                .frame(height: DockTitlePlateMetrics.height)
                .background(shape.fill(AppPalette.panel.swiftUI))
                .overlay { OnLookGlow(look: look, shape: AnyShape(shape), band: DockTitlePlateMetrics.glowBand) }
                .overlay(
                    shape.stroke(OutlineLook.frame(focused: model.isFocused).border.color.swiftUI, lineWidth: DockTitlePlateMetrics.borderStrokeWidth)
                )
                .clipShape(shape)
                .overlay {
                    OnLookSpinner(look: look, outline: .shape(AnyShape(shape)), stroke: DockTitlePlateMetrics.borderWidth)
                }
                // The top dock's plate reaches under a full-size-content titlebar, which the hosting view reads as a top safe
                // area and pushes the title down by. The plate is positioned by its host, so it takes no safe-area inset.
                .ignoresSafeArea()
        }
    }
}

/// The plate's host, laid over the top of its dock panel by `DockShellView`. It takes no clicks: a title isn't a control.
final class DockTitlePlateHost: NSHostingView<DockTitlePlateView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
