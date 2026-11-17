import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// SwiftUI top bar for the dock pane plus the small `@Observable` model the AppKit wrapper
/// pushes into. The wrapper (`ShellPaneContainers.swift`) keeps its public update methods and
/// writes to this model; the view re-renders reactively and forwards taps through the wrapper's
/// closures. Dock chrome decisions come from Core (`ShellChrome`); this layer only renders and
/// routes events. The terminal's own chrome is the action bar header (`app/Sources/App/ActionBar`).

@Observable
final class DockChromeModel {
    var topBar: DockTopBarModel
    /// Whether the dock has the keys, which lifts its title plate's border (`DockTitlePlateView`).
    var isFocused = false
    /// Whether the panel is refreshing what it lists, shown as the spinner beside its title. A closure, so the plate's body
    /// tracks the store behind it.
    let isRefreshing: () -> Bool

    init(
        topBar: DockTopBarModel = .make(
            mode: .artifacts,
            artifactRoute: .list,
            artifactTitle: nil,
            logAttached: false
        ),
        isRefreshing: @escaping () -> Bool = { false }
    ) {
        self.topBar = topBar
        self.isRefreshing = isRefreshing
    }
}

private extension View {
    /// Centres the bar's icon buttons on the line artifacts.svg draws them on. An offset, not padding: the buttons
    /// would otherwise reach past the bar's bottom and make it taller.
    func dockTopBarIcons() -> some View {
        frame(height: ChromeMetrics.iconHeight)
            .frame(maxHeight: .infinity)
            .offset(y: ShellMetrics.dockTopBarIconCentre - ShellMetrics.dockTopBarHeight / 2)
    }
}

struct DockTopBar: View {
    let model: DockChromeModel
    let onBack: (DockTopBarModel.Back) -> Void
    let onCopyArtifactPath: () -> Void
    let onRefreshArtifact: () -> Void
    let onToggleLogFilter: () -> Void
    /// A click on the bar that isn't on one of its buttons: it ends the log filter's dropdown, as one on the feed does.
    let onDismissLogFilter: () -> Void
    let onHideDock: () -> Void

    var body: some View {
        let topBar = model.topBar
        Group {
            if let back = topBar.back {
                viewerBar(topBar, back: back)
            } else {
                listBar(topBar)
            }
        }
        .padding(.horizontal, ShellMetrics.dockTopBarHorizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: ShellMetrics.dockTopBarHeight)
        .background(AppPalette.panel.swiftUI)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismissLogFilter)
        // The pane sits under the full-size-content titlebar; ignore its safe area
        // so the bar fills its 46pt frame instead of being inset downward.
        .ignoresSafeArea()
    }

    /// The titles sit on the plate over the panel's top edge (`DockTitlePlateView`), so the bar holds only its icons.
    private func listBar(_ topBar: DockTopBarModel) -> some View {
        HStack(spacing: Space.item) {
            Color.clear.frame(width: ChromeMetrics.iconWidth, height: 1)
            Spacer(minLength: 0)
            if topBar.showsLogFilter {
                ChromeIconButton(
                    symbolName: "line.3.horizontal.decrease",
                    accessibilityLabel: "Filter Worker Log",
                    tooltip: "Filter Worker Log (\(Keymap.badgeCharacter(for: .toggleFilterMenu) ?? ""))",
                    action: onToggleLogFilter
                )
            }
            ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock", action: onHideDock)
        }
        .dockTopBarIcons()
    }

    private func viewerBar(_ topBar: DockTopBarModel, back: DockTopBarModel.Back) -> some View {
        HStack(spacing: Space.item) {
            ChromeIconButton(symbolName: "arrow.backward", accessibilityLabel: backLabel(back)) {
                onBack(back)
            }
            .dockTopBarIcons()

            Spacer(minLength: 0)

            HStack(spacing: Space.item) {
                if topBar.showArtifactActions {
                    ChromeIconButton(symbolName: "doc.on.doc", accessibilityLabel: "Copy artifact path", action: onCopyArtifactPath)
                    ChromeIconButton(symbolName: "arrow.clockwise", accessibilityLabel: "Refresh artifact", action: onRefreshArtifact)
                }
                ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock", action: onHideDock)
            }
            .dockTopBarIcons()
        }
    }

    private func backLabel(_ back: DockTopBarModel.Back) -> String {
        switch back {
        case .artifactList: return "Back to artifacts"
        }
    }
}
