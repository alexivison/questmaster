import AppKit
import Observation
import QuestmasterCore
import SwiftUI

/// SwiftUI top bars for the three shell panes plus the small `@Observable` models
/// the AppKit wrappers push into. The wrappers (`ShellTopBars.swift`) keep their
/// public update methods and write to these models; the views re-render reactively
/// and forward taps through the wrapper's closures. Serve decisions come from
/// Core (`ShellChrome`); this layer only renders and routes events.

@Observable
final class TerminalChromeModel {
    var navigation: AppNavigationState
    var sessionChip: SelectedSessionChip?
    var serveState: ServeConnectionState
    var caffeineActive: Bool

    init(
        navigation: AppNavigationState = AppNavigationState(),
        sessionChip: SelectedSessionChip? = nil,
        serveState: ServeConnectionState = .starting,
        caffeineActive: Bool = false
    ) {
        self.navigation = navigation
        self.sessionChip = sessionChip
        self.serveState = serveState
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
            Spacer(minLength: 0)
            ChromeIconButton(symbolName: "plus.rectangle", accessibilityLabel: "New session", action: onNewSession)
            ChromeIconButton(symbolName: "sidebar.left", accessibilityLabel: "Hide Tracker", action: onHideTracker)
        }
        .padding(.horizontal, 16)
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

    var body: some View {
        let navigation = model.navigation
        HStack(spacing: 12) {
            if !navigation.trackerVisible {
                HStack(spacing: 8) {
                    Color.clear.frame(width: ShellMetrics.trafficLightReserve, height: 1)
                    ChromeIconButton(symbolName: "sidebar.left", accessibilityLabel: "Show Tracker") {
                        onShowTracker()
                    }
                }
            }
            ChromeSessionChip(chip: model.sessionChip)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                CaffeineButton(isActive: model.caffeineActive, action: onToggleCaffeine)
                ChromeDivider()
                ServeStatusPill(state: model.serveState)
                if !navigation.dockVisible {
                    ChromeDivider()
                    ChromeIconButton(symbolName: "sidebar.right", accessibilityLabel: "Open Artifacts") {
                        onOpenArtifacts()
                    }
                    ChromeIconButton(symbolName: "checklist", accessibilityLabel: "Open Quests") {
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
        HStack(spacing: 8) {
            if let back = topBar.back {
                ChromeIconButton(symbolName: "arrow.backward", accessibilityLabel: backLabel(back)) {
                    onBack(back)
                }
            }
            if let title = topBar.title {
                Text(title)
                    .font(AppFonts.bodyBold.swiftUI)
                    .foregroundStyle(AppPalette.bright.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if topBar.showArtifactActions {
                ChromeIconButton(symbolName: "doc.on.doc", accessibilityLabel: "Copy artifact path", action: onCopyArtifactPath)
                ChromeIconButton(symbolName: "arrow.clockwise", accessibilityLabel: "Refresh artifact", action: onRefreshArtifact)
            }
            ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Close Dock", action: onHideDock)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: ShellMetrics.topBarHeight)
        .background(AppPalette.panel.swiftUI)
        // The pane sits under the full-size-content titlebar; ignore its safe area
        // so the bar fills its 46pt frame instead of being inset downward.
        .ignoresSafeArea()
    }

    private func backLabel(_ back: DockTopBarModel.Back) -> String {
        switch back {
        case .artifactList: return "Back to artifacts"
        }
    }
}
