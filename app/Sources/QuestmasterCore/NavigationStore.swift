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
        mutate { $0.focus(region) }
    }

    @discardableResult
    public func toggleTracker() -> NavigationOutcome {
        mutate { $0.toggleTracker() }
    }

    @discardableResult
    public func toggleDock() -> NavigationOutcome {
        mutate { $0.toggleDock() }
    }

    @discardableResult
    public func directionalRegionFocus(_ direction: NavigationDirection) -> NavigationOutcome {
        mutate { $0.directionalRegionFocus(direction) }
    }

    @discardableResult
    public func terminalEdgeHandoff(_ direction: NavigationDirection) -> NavigationOutcome {
        mutate { $0.terminalEdgeHandoff(direction) }
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
