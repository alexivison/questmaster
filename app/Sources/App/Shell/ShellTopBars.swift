import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// SwiftUI top bar for the dock pane plus the small `@Observable` model the AppKit wrapper
/// pushes into. The wrapper (`ShellPaneContainers.swift`) keeps its public update methods and
/// writes to this model; the view re-renders reactively and forwards taps through the wrapper's
/// closures. Dock chrome decisions come from Core (`ShellChrome`); this layer only renders and
/// routes events. The terminal's own chrome is the action bar footer (`app/Sources/App/ActionBar`).

@Observable
final class DockChromeModel {
    var topBar: DockTopBarModel

    init(topBar: DockTopBarModel = .make(
        mode: .artifacts,
        artifactRoute: .list,
        artifactTitle: nil
    )) {
        self.topBar = topBar
    }
}

/// Every dock's title (Artifacts, Worker Chat, an open artifact's name): title case, in the one gold.
private func dockTopBarTitle(_ title: String) -> some View {
    BaselineText(title, font: AppFonts.dockTopBarTitle, color: AppPalette.accent, baseline: ShellMetrics.dockTopBarTitleBaseline)
        .lineLimit(1)
        .truncationMode(.tail)
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
        // The pane sits under the full-size-content titlebar; ignore its safe area
        // so the bar fills its 46pt frame instead of being inset downward.
        .ignoresSafeArea()
    }

    private func listBar(_ topBar: DockTopBarModel) -> some View {
        ZStack {
            HStack {
                Color.clear.frame(width: ChromeMetrics.iconWidth, height: 1)
                Spacer(minLength: 0)
                ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock", action: onHideDock)
            }
            .dockTopBarIcons()
            if let title = topBar.title {
                dockTopBarTitle(title)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ChromeMetrics.iconWidth + Token.Spacing.card)
                    .allowsHitTesting(false)
            }
        }
    }

    private func viewerBar(_ topBar: DockTopBarModel, back: DockTopBarModel.Back) -> some View {
        HStack(spacing: Token.Spacing.card) {
            ChromeIconButton(symbolName: "arrow.backward", accessibilityLabel: backLabel(back)) {
                onBack(back)
            }
            .dockTopBarIcons()

            if let title = topBar.title {
                dockTopBarTitle(title)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: Token.Spacing.card) {
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
