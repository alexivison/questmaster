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

    public init(focusedRegion: FocusRegion = .terminal, trackerVisible: Bool = true, dockVisible: Bool = true) {
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
        }
        focusedRegion = .terminal
        return .focused(.terminal)
    }

    @discardableResult
    public mutating func toggleDock() -> NavigationOutcome {
        dockVisible.toggle()
        if dockVisible {
            focusedRegion = .dock
            return .focused(.dock)
        }
        focusedRegion = .terminal
        return .focused(.terminal)
    }

    @discardableResult
    public mutating func terminalEdgeHandoff(_ direction: NavigationDirection) -> NavigationOutcome {
        guard let target = Self.terminalEdgeTarget(for: direction) else {
            return .unsupported
        }
        return focus(target)
    }

    @discardableResult
    public mutating func nativeControl(_ direction: NavigationDirection) -> NavigationOutcome {
        if direction == .up || direction == .down {
            return focusedRegion == .terminal ? .unchanged : .intraRegion(focusedRegion)
        }
        guard let target = Self.nativeEdgeTarget(from: focusedRegion, direction: direction) else {
            return .unchanged
        }
        return focus(target)
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

    public static func nativeEdgeTarget(from region: FocusRegion, direction: NavigationDirection) -> FocusRegion? {
        switch (region, direction) {
        case (.tracker, .right), (.dock, .left):
            return .terminal
        default:
            return nil
        }
    }
}
