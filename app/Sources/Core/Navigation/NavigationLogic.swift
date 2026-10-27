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

/// What a press of a dock panel's focus chord (⇧⌘K, ⇧⌘J) does: see `NavigationStore.dockPanelKeyRoute`.
public enum DockPanelKeyRoute: Equatable {
    /// Not the dock's key: it goes on, untouched, to whatever has the keys.
    case passThrough
    /// The dock's key, but the panel already has the keys: nothing to do.
    case alreadyFocused
    case focus
}

/// Where a Questmaster navigation chord goes before any menu or shell command handles it.
public enum CommandChordRoute: Equatable {
    case modal
    case shell
    case dock(DockPanelKeyRoute)
    case passThrough
}

public enum AppCommandKind: Equatable {
    case app
    case globalModal(GlobalModalCommand)
    case textEditing
    case quit
}

public enum AppCommandRoute: Equatable {
    case allowed
    case child
    case blockedByModal
}

public struct AppNavigationState: Equatable {
    public private(set) var focusedRegion: FocusRegion
    public private(set) var trackerVisible: Bool
    /// The dock region shows while either of its panels does (`DockPanels.isShown`).
    public private(set) var dockVisible: Bool
    /// The dock panel that has the keys while the dock is focused, and the one it comes back to.
    public private(set) var focusedDockPanel: DockPanel

    public init(
        focusedRegion: FocusRegion = .terminal,
        trackerVisible: Bool = true,
        dockVisible: Bool = false,
        focusedDockPanel: DockPanel = .bottom
    ) {
        if (focusedRegion == .tracker && !trackerVisible) || (focusedRegion == .dock && !dockVisible) {
            self.focusedRegion = .terminal
        } else {
            self.focusedRegion = focusedRegion
        }
        self.trackerVisible = trackerVisible
        self.dockVisible = dockVisible
        self.focusedDockPanel = focusedDockPanel
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

    /// Focuses one dock panel (showing the dock region if it was hidden); the caller has shown the panel.
    @discardableResult
    public mutating func focusDockPanel(_ panel: DockPanel) -> NavigationOutcome {
        dockVisible = true
        focusedDockPanel = panel
        focusedRegion = .dock
        return .focused(.dock)
    }

    @discardableResult
    public mutating func showDockPreservingFocus() -> NavigationOutcome {
        dockVisible = true
        return .unchanged
    }

    /// Fits the dock region to the panels that show, keeping focus where it is: the region shows while any panel does, and
    /// focus never rests on a hidden panel. When the focused panel hides, the keys pass to the other one, or to the
    /// terminal when none is left. Unlike `focusDockPanel`, showing a panel does not move focus to it.
    @discardableResult
    public mutating func settleDock(_ panels: DockPanels) -> NavigationOutcome {
        dockVisible = panels.isShown
        guard panels.isShown else {
            guard focusedRegion == .dock else {
                return .unchanged
            }
            focusedRegion = .terminal
            return .focused(.terminal)
        }
        guard !panels.contains(focusedDockPanel) else {
            return .unchanged
        }
        focusedDockPanel = panels.top ? .top : .bottom
        return focusedRegion == .dock ? .focused(.dock) : .unchanged
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

}
