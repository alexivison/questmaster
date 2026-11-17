import AppKit
import QuestmasterCore
import SwiftUI

/// The dock's title plate (the title tab): a nameplate centred on each dock panel's top edge, `lift` above it, so it breaks the
/// 2pt border and the double rule and hides both behind its panel fill. Its ends are `AngledButtonShape`, the angled
/// buttons' own, and its 2pt border lifts to `controlBorder` with the rule while the dock has the keys.
enum DockTitlePlateMetrics {
    static let height: CGFloat = 30
    /// How far the plate rises above the panel's top edge: the window's gap above the dock, less the plate's own headroom.
    static let lift = Space.item
    /// The plate's padding either side of the title.
    static let titleInset = Space.section
    /// The refresh spinner's gap past the title, as it was when the title sat in the top bar.
    static let spinnerGap = Space.item
    /// The plate's border, 2pt inside its outline: a stroke twice as wide, clipped to the shape.
    static let borderStrokeWidth = 2 * Token.Size.hairline
}

/// The title and, while the panel refreshes, the spinner `spinnerGap` past the title's end, on the plate's centre line. The
/// spinner sits outside the plate's clip, so it stays whole where it overhangs the angled end.
struct DockTitlePlateView: View {
    let model: DockChromeModel

    var body: some View {
        if let title = model.topBar.title {
            let shape = AngledButtonShape()
            Text(title)
                .font(AppFonts.dockTopBarTitle.swiftUI)
                .foregroundStyle(AppPalette.accent.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, DockTitlePlateMetrics.titleInset)
                .frame(height: DockTitlePlateMetrics.height)
                .background(shape.fill(AppPalette.panel.swiftUI))
                .overlay(
                    shape.stroke(OutlineLook.plate(focused: model.isFocused).border.color.swiftUI, lineWidth: DockTitlePlateMetrics.borderStrokeWidth)
                )
                .clipShape(shape)
                .overlay(alignment: .trailing) { refreshSpinner }
        }
    }

    /// Takes no room: it hangs past the title's padding, so the centred title never moves when it comes and goes.
    @ViewBuilder
    private var refreshSpinner: some View {
        if model.isRefreshing() {
            SpinnerRingView(stroke: ShellMetrics.dockTopBarSpinnerStroke)
                .frame(width: ShellMetrics.dockTopBarSpinnerSize, height: ShellMetrics.dockTopBarSpinnerSize)
                .offset(x: ShellMetrics.dockTopBarSpinnerSize - (DockTitlePlateMetrics.titleInset - DockTitlePlateMetrics.spinnerGap))
        }
    }
}

/// The plate's host, laid over the top of its dock panel by `DockShellView`. It takes no clicks: a title isn't a control.
final class DockTitlePlateHost: NSHostingView<DockTitlePlateView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
