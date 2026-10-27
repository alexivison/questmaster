import Foundation
import Observation

/// Observable owner of multi-pane navigation state.
///
/// Phase 0 wrapper around the pure `AppNavigationState` value-type state machine, extracted from
/// `AppDelegate` so navigation ownership lives outside the view controller. Mutating methods
/// forward to the wrapped value and return the same `NavigationOutcome` the caller acts on, so
/// existing call sites keep working unchanged. `@Observable` so SwiftUI chrome can read it directly
/// in later phases.
@Observable
public final class NavigationStore {
    public private(set) var state: AppNavigationState

    public init(state: AppNavigationState = AppNavigationState()) {
        self.state = state
    }

    public var focusedRegion: FocusRegion {
        state.focusedRegion
    }

    /// A modal is drawn over the panes: the keys go to it, so no region has them.
    public private(set) var isModalDrawn = false

    public func setModalDrawn(_ drawn: Bool) {
        guard isModalDrawn != drawn else {
            return
        }
        isModalDrawn = drawn
    }

    /// Whether `region` takes the keys: it's the focused region and no modal is drawn. Its focus looks (the dock's
    /// frame and tabs, the tracker's cursor) follow this, not the focused region alone.
    public func hasKeys(_ region: FocusRegion) -> Bool {
        focusedRegion == region && !isModalDrawn
    }

    /// Whether one dock panel takes the keys: the dock has them and this panel is the focused one. Only that panel's
    /// frame lifts.
    public func hasKeys(_ panel: DockPanel) -> Bool {
        hasKeys(.dock) && state.focusedDockPanel == panel
    }

    public var focusedDockPanel: DockPanel {
        state.focusedDockPanel
    }

    /// What the chord that focuses `panel` does inside dock routing. The dock handles it only while it has the keys
    /// (`hasKeys`) and both panels show. `commandChordRoute` gives an open modal first refusal before this route;
    /// anywhere else the chord goes on to the focused responder, including Ghostty's ⇧⌘J binding.
    public func dockPanelKeyRoute(_ panel: DockPanel, panels: DockPanels) -> DockPanelKeyRoute {
        guard hasKeys(.dock), panels.top, panels.bottom else {
            return .passThrough
        }
        return state.focusedDockPanel == panel ? .alreadyFocused : .focus
    }

    /// The modal owns every navigation chord while it is drawn; otherwise H/L focus shell regions and J/K retain
    /// their two-panel dock scope, passing through to the terminal everywhere else.
    public func commandChordRoute(_ direction: NavigationDirection, panels: DockPanels) -> CommandChordRoute {
        guard !isModalDrawn else {
            return .modal
        }
        switch direction {
        case .left, .right:
            return .shell
        case .up:
            return dockRoute(.top, panels: panels)
        case .down:
            return dockRoute(.bottom, panels: panels)
        }
    }

    /// App commands pause while a modal is drawn. Standard text editing and Quit remain available.
    public func appCommandRoute(_ kind: AppCommandKind) -> AppCommandRoute {
        guard isModalDrawn, kind == .app else {
            return .allowed
        }
        return .blockedByModal
    }

    private func dockRoute(_ panel: DockPanel, panels: DockPanels) -> CommandChordRoute {
        switch dockPanelKeyRoute(panel, panels: panels) {
        case .passThrough:
            return .passThrough
        case .alreadyFocused:
            return .dock(.alreadyFocused)
        case .focus:
            return .dock(.focus)
        }
    }

    public var trackerVisible: Bool {
        state.trackerVisible
    }

    public var dockVisible: Bool {
        state.dockVisible
    }

    @discardableResult
    public func focus(_ region: FocusRegion) -> NavigationOutcome {
        mutate { $0.focus(region) }
    }

    @discardableResult
    public func toggleTracker() -> NavigationOutcome {
        mutate { $0.toggleTracker() }
    }

    @discardableResult
    public func focusDockPanel(_ panel: DockPanel) -> NavigationOutcome {
        mutate { $0.focusDockPanel(panel) }
    }

    @discardableResult
    public func showDockPreservingFocus() -> NavigationOutcome {
        mutate { $0.showDockPreservingFocus() }
    }

    @discardableResult
    public func settleDock(_ panels: DockPanels) -> NavigationOutcome {
        mutate { $0.settleDock(panels) }
    }

    @discardableResult
    public func directionalRegionFocus(_ direction: NavigationDirection) -> NavigationOutcome {
        mutate { $0.directionalRegionFocus(direction) }
    }

    @discardableResult
    public func nativeControl(_ direction: NavigationDirection) -> NavigationOutcome {
        mutate { $0.nativeControl(direction) }
    }

    /// Mutates the wrapped state via a local copy and assigns it back, so the `@Observable`
    /// change is triggered by a property *assignment* (in-place mutation of a value-type stored
    /// property is not reliably observed). Keeps SwiftUI consumers correct in later phases.
    @discardableResult
    private func mutate(_ body: (inout AppNavigationState) -> NavigationOutcome) -> NavigationOutcome {
        var newState = state
        let outcome = body(&newState)
        state = newState
        return outcome
    }
}
