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

    /// What the chord that focuses `panel` does. The chords move the keys between the dock's two panels, so they are
    /// the dock's own: handled only while the dock has the keys (`hasKeys`) and both panels show. Anywhere else (the
    /// terminal, the tracker, under a modal, a dock with one panel) they are not handled and go on to whoever has the
    /// focus, Ghostty's own ⇧⌘J binding included.
    public func dockPanelKeyRoute(_ panel: DockPanel, panels: DockPanels) -> DockPanelKeyRoute {
        guard hasKeys(.dock), panels.top, panels.bottom else {
            return .passThrough
        }
        return state.focusedDockPanel == panel ? .alreadyFocused : .focus
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
