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

    public var trackerVisible: Bool {
        state.trackerVisible
    }

    public var dockVisible: Bool {
        state.dockVisible
    }

    @discardableResult
    public func focus(_ region: FocusRegion) -> NavigationOutcome {
        state.focus(region)
    }

    @discardableResult
    public func toggleTracker() -> NavigationOutcome {
        state.toggleTracker()
    }

    @discardableResult
    public func toggleDock() -> NavigationOutcome {
        state.toggleDock()
    }

    @discardableResult
    public func directionalRegionFocus(_ direction: NavigationDirection) -> NavigationOutcome {
        state.directionalRegionFocus(direction)
    }

    @discardableResult
    public func terminalEdgeHandoff(_ direction: NavigationDirection) -> NavigationOutcome {
        state.terminalEdgeHandoff(direction)
    }

    @discardableResult
    public func nativeControl(_ direction: NavigationDirection) -> NavigationOutcome {
        state.nativeControl(direction)
    }
}
