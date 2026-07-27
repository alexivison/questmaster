import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// SwiftUI top bars for the three shell panes plus the small `@Observable` models
/// the AppKit wrappers push into. The wrappers (`ShellPaneContainers.swift`) keep their
/// public update methods and write to these models; the views re-render reactively
/// and forward taps through the wrapper's closures. Dock chrome decisions come from
/// Core (`ShellChrome`); this layer only renders and routes events.

/// Native hover tooltip text for a shortcut-bearing control: label, then the shortcut
/// glyph, single-sourced from the Keymap binding so it can't drift from the real shortcut.
private func tooltip(_ label: String, _ binding: Keymap.CommandBinding) -> String {
    "\(label)  \(binding.displayGlyph)"
}

@Observable
final class TerminalChromeModel {
    var navigation: AppNavigationState
    var sessionChip: SelectedSessionChip?
    var caffeineActive: Bool

    init(
        navigation: AppNavigationState = AppNavigationState(),
        sessionChip: SelectedSessionChip? = nil,
        caffeineActive: Bool = false
    ) {
        self.navigation = navigation
        self.sessionChip = sessionChip
        self.caffeineActive = caffeineActive
    }
}

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

struct TrackerTopBar: View {
    let onNewSession: () -> Void
    let onHideTracker: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Color.clear.frame(width: ShellMetrics.trafficLightReserve, height: 1)
                .padding(.leading, ShellMetrics.sideCardTopBarHorizontalInset)
            Spacer(minLength: 0)
            ChromeIconButton(
                symbolName: "plus.rectangle",
                accessibilityLabel: "New session",
                tooltip: tooltip("New Session", Keymap.Command.newSession),
                action: onNewSession
            )
            ChromeIconButton(
                symbolName: "sidebar.left",
                accessibilityLabel: "Hide Tracker",
                tooltip: tooltip("Hide Tracker", Keymap.Command.toggleTracker),
                action: onHideTracker
            )
        }
        .padding(.leading, ShellMetrics.sideCardTopBarHorizontalInset)
        .padding(.trailing, ShellMetrics.trackerTopBarControlTrailingInset)
        .frame(maxWidth: .infinity)
        .frame(height: ShellMetrics.topBarHeight)
        .background(AppPalette.panel.swiftUI)
        // The pane sits under the full-size-content titlebar; ignore its safe area
        // so the bar fills its 46pt frame instead of being inset downward.
        .ignoresSafeArea()
    }
}

struct TerminalTopBar: View {
    let model: TerminalChromeModel
    let onShowTracker: () -> Void
    let onOpenArtifacts: () -> Void
    let onOpenQuests: () -> Void
    let onToggleCaffeine: () -> Void
    let onCopySessionID: (String) -> Void

    var body: some View {
        let navState = model.navigation
        HStack(spacing: 12) {
            if !navState.trackerVisible {
                HStack(spacing: 8) {
                    Color.clear.frame(width: ShellMetrics.trafficLightReserve, height: 1)
                    ChromeIconButton(
                        symbolName: "sidebar.left",
                        accessibilityLabel: "Show Tracker",
                        tooltip: tooltip("Show Tracker", Keymap.Command.toggleTracker)
                    ) {
                        onShowTracker()
                    }
                }
            }
            ChromeSessionChip(
                chip: model.sessionChip,
                shortcutGlyph: Keymap.Command.copySessionID.displayGlyph,
                onCopySessionID: onCopySessionID
            )
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                CaffeineButton(
                    isActive: model.caffeineActive,
                    shortcutGlyph: Keymap.Command.toggleCaffeine.displayGlyph,
                    action: onToggleCaffeine
                )
                if !navState.dockVisible {
                    ChromeDivider()
                    ChromeIconButton(
                        symbolName: "doc.richtext",
                        accessibilityLabel: "Open Artifacts",
                        tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock)
                    ) {
                        onOpenArtifacts()
                    }
                    ChromeIconButton(
                        symbolName: "checklist",
                        accessibilityLabel: "Open Quests",
                        tooltip: tooltip("Open Quests", Keymap.Command.toggleQuestDock)
                    ) {
                        onOpenQuests()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: ShellMetrics.topBarHeight)
        .background(AppPalette.window.swiftUI)
        // The terminal pane sits under the full-size-content titlebar; ignore its
        // safe area so the bar fills its 46pt frame instead of being inset downward.
        .ignoresSafeArea()
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
        .padding(.leading, ShellMetrics.dockTopBarLeadingInset)
        .padding(.trailing, ShellMetrics.sideCardTopBarHorizontalInset)
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
            if let title = topBar.title {
                dockTitle(title)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ChromeMetrics.iconWidth + Token.Spacing.card)
                    .allowsHitTesting(false)
            }
        }
    }

    private func viewerBar(_ topBar: DockTopBarModel, back: DockTopBarModel.Back) -> some View {
        HStack(spacing: Token.Spacing.card) {
            HStack(spacing: 0) {
                ChromeIconButton(symbolName: "arrow.backward", accessibilityLabel: backLabel(back)) {
                    onBack(back)
                }
                Color.clear
                    .frame(minWidth: 0, maxWidth: 56)
                    .layoutPriority(-1)
            }

            if let title = topBar.title {
                FlankedOrnamentRule {
                    dockTitle(title)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: Token.Spacing.card) {
                if topBar.showArtifactActions {
                    ChromeIconButton(symbolName: "doc.on.doc", accessibilityLabel: "Copy artifact path", action: onCopyArtifactPath)
                    ChromeIconButton(symbolName: "arrow.clockwise", accessibilityLabel: "Refresh artifact", action: onRefreshArtifact)
                }
                ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock", action: onHideDock)
            }
        }
    }

    private func dockTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFonts.dockTopBarTitle.swiftUI)
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(AppPalette.accent.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func backLabel(_ back: DockTopBarModel.Back) -> String {
        switch back {
        case .artifactList: return "Back to artifacts"
        }
    }
}
