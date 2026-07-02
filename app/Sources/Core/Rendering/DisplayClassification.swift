import Foundation

/// Typed classification of the stringly-typed identity fields that arrive from the serve backend.
///
/// Phase 1 of the architecture modernization: parsing the raw strings happens once,
/// here in Core (testable, no AppKit), so the AppKit/SwiftUI color mapping can switch over an
/// exhaustive enum instead of re-implementing `lowercased()` / `switch` ladders in the view layer.

public enum AgentKind: String, Equatable, CaseIterable {
    case claude
    case codex
    case opencode
    case pi
    case omp
    case shell
    case unknown

    public init(name: String) {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "shell":
            self = .shell
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

    /// Human-facing, capitalized label for a known agent. `.unknown` returns an
    /// empty string; use `displayName(for:)` to render arbitrary identifiers.
    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        case .pi:
            return "Pi"
        case .omp:
            return "OMP"
        case .shell:
            return "Shell"
        case .unknown:
            return ""
        }
    }

    /// Capitalized label for any agent identifier. Known agents use their brand
    /// casing; unknown identifiers fall back to capitalizing the first letter.
    public static func displayName(for name: String) -> String {
        let kind = AgentKind(name: name)
        if kind != .unknown {
            return kind.displayName
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return trimmed
        }
        return first.uppercased() + trimmed.dropFirst()
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

public enum SessionActivityStatusKind: String, Equatable, CaseIterable {
    case working
    case blocked
    case done
    case stopped
    case other

    public init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "working", "starting", "checking":
            self = .working
        case "blocked", "error", "failed", "fail":
            self = .blocked
        case "done", "pass", "passed", "ok":
            self = .done
        case "stopped":
            self = .stopped
        default:
            self = .other
        }
    }
}
