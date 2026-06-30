import Foundation

public enum NavigationDirection: String, Equatable {
    case left
    case down
    case up
    case right

    public static func parse(_ value: String) -> NavigationDirection? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h", "left":
            return .left
        case "j", "down":
            return .down
        case "k", "up":
            return .up
        case "l", "right":
            return .right
        default:
            return nil
        }
    }
}

public enum FocusRegion: String, Equatable {
    case tracker
    case terminal
    case dock
}

public enum NavigationOutcome: Equatable {
    case focused(FocusRegion)
    case intraRegion(FocusRegion)
    case unsupported
    case unchanged
}

public struct AppNavigationState: Equatable {
    public private(set) var focusedRegion: FocusRegion
    public private(set) var trackerVisible: Bool
    public private(set) var dockVisible: Bool

    public init(focusedRegion: FocusRegion = .terminal, trackerVisible: Bool = true, dockVisible: Bool = false) {
        if (focusedRegion == .tracker && !trackerVisible) || (focusedRegion == .dock && !dockVisible) {
            self.focusedRegion = .terminal
        } else {
            self.focusedRegion = focusedRegion
        }
        self.trackerVisible = trackerVisible
        self.dockVisible = dockVisible
    }

    @discardableResult
    public mutating func focus(_ region: FocusRegion) -> NavigationOutcome {
        if region == .tracker {
            trackerVisible = true
        }
        if region == .dock {
            dockVisible = true
        }
        focusedRegion = region
        return .focused(region)
    }

    @discardableResult
    public mutating func toggleTracker() -> NavigationOutcome {
        trackerVisible.toggle()
        if trackerVisible {
            focusedRegion = .tracker
            return .focused(.tracker)
        } else {
            focusedRegion = .terminal
            return .focused(.terminal)
        }
    }

    @discardableResult
    public mutating func toggleDock() -> NavigationOutcome {
        dockVisible.toggle()
        if dockVisible {
            focusedRegion = .dock
            return .focused(.dock)
        } else {
            focusedRegion = .terminal
            return .focused(.terminal)
        }
    }

    @discardableResult
    public mutating func selectRegionTab(_ region: FocusRegion) -> NavigationOutcome {
        switch region {
        case .tracker:
            return toggleTracker()
        case .terminal:
            return focus(.terminal)
        case .dock:
            return toggleDock()
        }
    }

    @discardableResult
    public mutating func showDockPreservingFocus() -> NavigationOutcome {
        dockVisible = true
        return .unchanged
    }

    /// Sets dock visibility while preserving focus, re-applying the focus invariant.
    ///
    /// Unlike `focus(.dock)`, showing the dock does NOT move focus to it. Hiding the dock while it
    /// is focused strands focus, so focus falls back to `.terminal` (mirroring the constructor
    /// invariant and `toggleDock()`). Setting visibility to its current value is a no-op for focus.
    @discardableResult
    public mutating func setDockVisible(_ visible: Bool) -> NavigationOutcome {
        dockVisible = visible
        if !visible && focusedRegion == .dock {
            focusedRegion = .terminal
            return .focused(.terminal)
        }
        return .unchanged
    }

    @discardableResult
    public mutating func directionalRegionFocus(_ direction: NavigationDirection) -> NavigationOutcome {
        let target = Self.directionalRegionTarget(
            from: focusedRegion,
            direction: direction,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        )
        guard target != focusedRegion else {
            return .unchanged
        }
        focusedRegion = target
        return .focused(target)
    }

    @discardableResult
    public mutating func terminalEdgeHandoff(_ direction: NavigationDirection) -> NavigationOutcome {
        guard let target = Self.terminalEdgeTarget(for: direction) else {
            return .unsupported
        }
        switch target {
        case .tracker where !trackerVisible,
             .dock where !dockVisible:
            return .unsupported
        case .tracker, .terminal, .dock:
            break
        }
        return focus(target)
    }

    @discardableResult
    public mutating func nativeControl(_ direction: NavigationDirection) -> NavigationOutcome {
        switch direction {
        case .up, .down:
            return focusedRegion == .terminal ? .unchanged : .intraRegion(focusedRegion)
        case .right where focusedRegion == .tracker,
             .left where focusedRegion == .dock:
            return focus(.terminal)
        case .left, .right:
            return .unsupported
        }
    }

    public static func directionalRegionTarget(
        from region: FocusRegion,
        direction: NavigationDirection,
        trackerVisible: Bool = true,
        dockVisible: Bool = true
    ) -> FocusRegion {
        let order = visibleDirectionalRegionOrder(trackerVisible: trackerVisible, dockVisible: dockVisible)
        guard let index = order.firstIndex(of: region) else {
            return region
        }

        switch direction {
        case .left:
            guard index > order.startIndex else {
                return region
            }
            return order[order.index(before: index)]
        case .right:
            let nextIndex = order.index(after: index)
            guard nextIndex < order.endIndex else {
                return region
            }
            return order[nextIndex]
        case .up, .down:
            return region
        }
    }

    private static func visibleDirectionalRegionOrder(trackerVisible: Bool, dockVisible: Bool) -> [FocusRegion] {
        var order: [FocusRegion] = []
        if trackerVisible {
            order.append(.tracker)
        }
        order.append(.terminal)
        if dockVisible {
            order.append(.dock)
        }
        return order
    }

    public static func terminalEdgeTarget(for direction: NavigationDirection) -> FocusRegion? {
        switch direction {
        case .left:
            return .tracker
        case .right:
            return .dock
        case .up, .down:
            return nil
        }
    }

}
