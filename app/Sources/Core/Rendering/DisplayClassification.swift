import Foundation

/// Typed classification of the stringly-typed identity fields that arrive from the serve backend.
///
/// Phase 1 of `app/docs/architecture-modernization-plan.md`: parsing the raw strings happens once,
/// here in Core (testable, no AppKit), so the AppKit/SwiftUI color mapping can switch over an
/// exhaustive enum instead of re-implementing `lowercased()` / `switch` ladders in the view layer.

public enum AgentKind: String, Equatable, CaseIterable {
    case claude
    case codex
    case opencode
    case pi
    case omp
    case unknown

    public init(name: String) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude":
            self = .claude
        case "codex":
            self = .codex
        case "opencode":
            self = .opencode
        case "pi":
            self = .pi
        case "omp":
            self = .omp
        default:
            self = .unknown
        }
    }
}

public enum SessionRoleKind: String, Equatable, CaseIterable {
    case master
    case worker
    case tmux
    case orphan
    case standalone

    public init(role: String) {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "master", "primary":
            self = .master
        case "worker":
            self = .worker
        case "tmux":
            self = .tmux
        case "orphan":
            self = .orphan
        default:
            self = .standalone
        }
    }
}

public enum QuestStatusKind: String, Equatable, CaseIterable {
    case active
    case done
    case other

    public init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active":
            self = .active
        case "done":
            self = .done
        default:
            self = .other
        }
    }
}
