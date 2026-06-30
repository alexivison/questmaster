import Foundation

public enum ShellFocusEffect: Equatable {
    case focus(FocusRegion)
    case refresh
}

public enum ShellFocusLogic {
    public static func effect(for outcome: NavigationOutcome) -> ShellFocusEffect {
        switch outcome {
        case .focused(let region):
            return .focus(region)
        case .intraRegion, .unsupported, .unchanged:
            return .refresh
        }
    }
}

public extension AppNavigationState {
    @discardableResult
    mutating func selectRegionTab(_ region: FocusRegion) -> NavigationOutcome {
        switch region {
        case .tracker:
            return toggleTracker()
        case .terminal:
            return focus(.terminal)
        case .dock:
            return toggleDock()
        }
    }
}
