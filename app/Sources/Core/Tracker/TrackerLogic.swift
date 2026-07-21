import Foundation

public enum TrackerStatusKind {
    case working
    case blocked
    case done
    case idle
    case stopped
    case needsInput
    case error
}

public enum TrackerStatusIndicatorAffordance {
    case spinner
    case circle
    case ring
    case square
    case roundedSquare
}

public struct TrackerStatusClassification {
    public let kind: TrackerStatusKind
    public let label: String
    public let indicatorAffordance: TrackerStatusIndicatorAffordance
    public let showsBadge: Bool

    public init(
        kind: TrackerStatusKind,
        label: String,
        indicatorAffordance: TrackerStatusIndicatorAffordance,
        showsBadge: Bool = true
    ) {
        self.kind = kind
        self.label = label
        self.indicatorAffordance = indicatorAffordance
        self.showsBadge = showsBadge
    }
}

public enum TrackerStatusClassifier {
    public static func classify(_ session: TrackerSession) -> TrackerStatusClassification {
        let rawState = session.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawLifecycle = session.lifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lastKind = session.lastKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isActiveShell = AgentKind(name: session.agent) == .shell && rawLifecycle == "active"

        if rawLifecycle == "stopped"
            || rawLifecycle == "exited"
            || (!isActiveShell && (rawState == "stopped" || rawState == "exited")) {
            let label = rawLifecycle == "exited" || rawState == "exited" ? "exited - continue" : "stopped - continue"
            return TrackerStatusClassification(kind: .stopped, label: label, indicatorAffordance: .roundedSquare)
        }
        if isActiveShell {
            return TrackerStatusClassification(kind: .idle, label: "active", indicatorAffordance: .circle, showsBadge: false)
        }
        if isErrorKind(lastKind) {
            return TrackerStatusClassification(kind: .error, label: "error", indicatorAffordance: .square)
        }
        if isNeedsInputState(rawState) || isNeedsInputKind(lastKind) {
            return TrackerStatusClassification(kind: .needsInput, label: "needs input", indicatorAffordance: .ring)
        }

        switch rawState {
        case "working":
            return TrackerStatusClassification(kind: .working, label: rawState.isEmpty ? "working" : rawState, indicatorAffordance: .spinner)
        case "starting":
            return TrackerStatusClassification(kind: .idle, label: "idle (started)", indicatorAffordance: .circle)
        case "checking":
            return TrackerStatusClassification(kind: .idle, label: "checking", indicatorAffordance: .circle)
        case "blocked":
            return TrackerStatusClassification(kind: .blocked, label: "blocked", indicatorAffordance: .circle)
        case "error", "failed", "fail":
            return TrackerStatusClassification(kind: .error, label: "error", indicatorAffordance: .square)
        case "done", "pass", "passed", "ok":
            return TrackerStatusClassification(kind: .done, label: "done", indicatorAffordance: .circle)
        case "active", "unknown", "":
            return TrackerStatusClassification(
                kind: .idle,
                label: rawLifecycle == "active" ? "active" : "idle",
                indicatorAffordance: .circle
            )
        default:
            return TrackerStatusClassification(kind: .idle, label: rawState, indicatorAffordance: .circle)
        }
    }

    private static func isNeedsInputState(_ state: String) -> Bool {
        ["needs-input", "needs_input", "needs input", "waiting_for_user", "waiting-for-user", "input"].contains(state)
    }

    private static func isNeedsInputKind(_ kind: String) -> Bool {
        ["waiting_for_user", "permission_prompt", "approval_prompt", "ask_user_question", "permission.asked"].contains(kind)
    }

    private static func isErrorKind(_ kind: String) -> Bool {
        ["session.error"].contains(kind)
    }
}

public enum TrackerActivationIntent: Equatable {
    case switchSession
    case continueSession
}

public enum TrackerActivationAction: Equatable {
    case focusCurrentSession
    case switchSession
    case continueSession
}

public enum TrackerActivationDecision {
    public static func intent(for session: TrackerSession) -> TrackerActivationIntent {
        TrackerStatusClassifier.classify(session).kind == .stopped ? .continueSession : .switchSession
    }

    public static func action(
        for session: TrackerSession,
        currentTerminalSessionID: String?,
        sessionIsCurrent: Bool = false
    ) -> TrackerActivationAction {
        switch intent(for: session) {
        case .continueSession:
            return .continueSession
        case .switchSession:
            let currentID = cleanID(currentTerminalSessionID ?? "")
            if !currentID.isEmpty && cleanID(session.id) == currentID {
                return .focusCurrentSession
            }
            return .switchSession
        }
    }

    private static func cleanID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TrackerActivationTarget {
    public static func session(
        openedID: String?,
        selectedID: String?,
        sessions: [TrackerSession]
    ) -> TrackerSession? {
        if let openedID,
           let session = sessions.first(where: { $0.id == openedID }) {
            return session
        }
        guard let selectedID else {
            return nil
        }
        return sessions.first { $0.id == selectedID }
    }
}

public struct TrackerDeleteRecoveryTarget: Equatable {
    public let sessionID: String
    public let intent: TrackerActivationIntent

    public init(sessionID: String, intent: TrackerActivationIntent) {
        self.sessionID = sessionID
        self.intent = intent
    }
}

public enum TrackerSelection {
    /// Whether the rendered selection should jump to `currentSessionID`, given the value it
    /// held last time this ran. Returns non-nil only when the *active* session itself just
    /// changed (any path -- click, keyboard shortcut, or elsewhere) and the new one still
    /// exists in `sessions`; a snapshot refresh where the active session didn't change
    /// returns nil, so a deliberate arrow-key selection of a different row survives it.
    public static func followCurrentSessionID(
        previousCurrentSessionID: String?,
        currentSessionID: String?,
        sessions: [TrackerSession]
    ) -> String? {
        guard currentSessionID != previousCurrentSessionID,
              let currentSessionID,
              sessions.contains(where: { $0.id == currentSessionID }) else {
            return nil
        }
        return currentSessionID
    }

    public static func nextSelectionID(
        currentID: String?,
        sessions: [TrackerSession],
        delta: Int
    ) -> String? {
        RepoListSelection.nextSelectionID(
            currentID: currentID,
            ids: sessions.map(\.id),
            delta: delta
        )
    }

    public static func nextNeedsInputID(
        currentID: String?,
        sessions: [TrackerSession]
    ) -> String? {
        guard !sessions.isEmpty else {
            return nil
        }
        let currentIndex = currentID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? -1
        for offset in 1...sessions.count {
            let index = RepoListSelection.wrapped(currentIndex + offset, count: sessions.count)
            if TrackerStatusClassifier.classify(sessions[index]).kind == .needsInput {
                return sessions[index].id
            }
        }
        return nil
    }

    public static func nextActiveAfterDeleteID(
        deleted: TrackerSession,
        sessions: [TrackerSession]
    ) -> String? {
        nextAfterDeleteTarget(deleted: deleted, sessions: sessions)?.sessionID
    }

    public static func switchBeforeDeleteID(
        deleted: TrackerSession,
        sessions: [TrackerSession],
        currentTerminalSessionID: String?
    ) -> String? {
        switchBeforeDeleteTarget(
            deleted: deleted,
            sessions: sessions,
            currentTerminalSessionID: currentTerminalSessionID
        )?.sessionID
    }

    public static func switchBeforeDeleteTarget(
        deleted: TrackerSession,
        sessions: [TrackerSession],
        currentTerminalSessionID: String?
    ) -> TrackerDeleteRecoveryTarget? {
        guard deleteAffectsSessionID(
            deleted: deleted,
            sessions: sessions,
            sessionID: currentTerminalSessionID
        ) else {
            return nil
        }
        return nextAfterDeleteTarget(deleted: deleted, sessions: sessions)
    }

    public static func deleteAffectsSessionID(
        deleted: TrackerSession,
        sessions: [TrackerSession],
        sessionID: String?
    ) -> Bool {
        let currentID = cleanID(sessionID ?? "")
        guard !currentID.isEmpty else {
            return false
        }
        return affectedDeleteIDs(deleted: deleted, sessions: sessions).contains(currentID)
    }

    private static func normalizedRole(_ role: String) -> String {
        let value = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "primary" ? "master" : value
    }

    private static func normalizedLifecycle(_ lifecycle: String) -> String {
        lifecycle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nextAfterDeleteTarget(
        deleted: TrackerSession,
        sessions: [TrackerSession]
    ) -> TrackerDeleteRecoveryTarget? {
        guard !sessions.isEmpty else {
            return nil
        }

        let deletedID = cleanID(deleted.id)
        let deletedIDs = affectedDeleteIDs(deleted: deleted, sessions: sessions)
        let orderedSessions = sessionsOrderedForDeleteRecovery(deletedID: deletedID, sessions: sessions)

        func isUnaffected(_ session: TrackerSession) -> Bool {
            !deletedIDs.contains(cleanID(session.id))
        }

        for session in orderedSessions
        where normalizedLifecycle(session.lifecycle) == "active" && isUnaffected(session) {
            return TrackerDeleteRecoveryTarget(sessionID: session.id, intent: .switchSession)
        }
        for session in orderedSessions
        where isStoppedLifecycle(session.lifecycle) && isUnaffected(session) {
            return TrackerDeleteRecoveryTarget(sessionID: session.id, intent: .continueSession)
        }
        return nil
    }

    private static func sessionsOrderedForDeleteRecovery(
        deletedID: String,
        sessions: [TrackerSession]
    ) -> [TrackerSession] {
        guard let index = sessions.firstIndex(where: { cleanID($0.id) == deletedID }) else {
            return sessions
        }

        var ordered: [TrackerSession] = []
        if index > 0 {
            ordered.append(contentsOf: sessions[..<index].reversed())
        }
        if index + 1 < sessions.count {
            ordered.append(contentsOf: sessions[(index + 1)...])
        }
        return ordered
    }

    private static func isStoppedLifecycle(_ lifecycle: String) -> Bool {
        let value = normalizedLifecycle(lifecycle)
        return value == "stopped" || value == "exited"
    }

    private static func affectedDeleteIDs(
        deleted: TrackerSession,
        sessions: [TrackerSession]
    ) -> Set<String> {
        let deletedID = cleanID(deleted.id)
        var ids = Set([deletedID])
        if normalizedRole(deleted.role) == "master" {
            for session in sessions
            where normalizedRole(session.role) == "worker"
                && cleanID(session.parentID) == deletedID {
                ids.insert(cleanID(session.id))
            }
        }
        return ids
    }

    private static func cleanID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RepoListSelection {
    public static func validSelectionID(currentID: String?, ids: [String]) -> String? {
        guard !ids.isEmpty else {
            return nil
        }
        if let currentID, ids.contains(currentID) {
            return currentID
        }
        return ids.first
    }

    public static func nextSelectionID(currentID: String?, ids: [String], delta: Int) -> String? {
        guard !ids.isEmpty else {
            return nil
        }
        guard delta != 0 else {
            return validSelectionID(currentID: currentID, ids: ids)
        }

        let currentIndex = currentID.flatMap { ids.firstIndex(of: $0) }
        let baseIndex = currentIndex ?? (delta > 0 ? -1 : 0)
        return ids[wrapped(baseIndex + delta, count: ids.count)]
    }

    public static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}

public enum TrackerRecolorScope: String, CaseIterable {
    case session
    case repo
}

public struct TrackerColorSwatch: Equatable {
    public let name: String
    public let cssVariable: String

    public init(name: String) {
        self.name = name
        self.cssVariable = "--c-\(name)"
    }
}

public struct TrackerRecolorTarget: Equatable {
    public let sessionID: String
    public let role: String
    public let repoIdentity: String
    public let displayColor: String
    public let repoColor: String

    public init(
        sessionID: String,
        role: String,
        repoIdentity: String,
        displayColor: String,
        repoColor: String
    ) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repoIdentity = repoIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayColor = displayColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.repoColor = repoColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isSessionScopeAvailable: Bool {
        !sessionID.isEmpty && role.lowercased() != "worker"
    }

    public var isRepoScopeAvailable: Bool {
        !repoIdentity.isEmpty
    }

    public func isAvailable(_ scope: TrackerRecolorScope) -> Bool {
        switch scope {
        case .session:
            return isSessionScopeAvailable
        case .repo:
            return isRepoScopeAvailable
        }
    }

    public func currentColor(for scope: TrackerRecolorScope) -> String {
        switch scope {
        case .session:
            return displayColor
        case .repo:
            return repoColor
        }
    }
}

public struct TrackerRecolorPickerState: Equatable {
    public static let swatches = [
        "blue",
        "green",
        "yellow",
        "magenta",
        "cyan",
        "red",
        "orange",
        "gold",
        "lime",
        "teal",
        "sky",
        "indigo",
        "violet",
        "pink",
    ].map(TrackerColorSwatch.init(name:))

    public let target: TrackerRecolorTarget
    public private(set) var scope: TrackerRecolorScope
    public private(set) var selectedIndex: Int

    public init?(target: TrackerRecolorTarget, preferredScope: TrackerRecolorScope = .session) {
        guard target.isAvailable(preferredScope) else {
            return nil
        }
        self.target = target
        self.scope = preferredScope
        selectedIndex = Self.index(for: target.currentColor(for: preferredScope))
    }

    public var selectedSwatch: TrackerColorSwatch? {
        guard Self.swatches.indices.contains(selectedIndex) else {
            return nil
        }
        return Self.swatches[selectedIndex]
    }

    public mutating func cycle(delta: Int) {
        selectedIndex = RepoListSelection.wrapped(selectedIndex + delta, count: Self.swatches.count)
    }

    public mutating func selectColor(named name: String) {
        selectedIndex = Self.index(for: name)
    }

    public func selectedColorRequest() throws -> ServeMutationRequest {
        try request(color: selectedSwatch?.name ?? "")
    }

    public func clearRequest() throws -> ServeMutationRequest {
        try request(color: "")
    }

    public func request(color: String) throws -> ServeMutationRequest {
        switch scope {
        case .session:
            return try ServeMutationRequests.recolorSession(sessionID: target.sessionID, color: color)
        case .repo:
            return try ServeMutationRequests.recolorRepo(repoIdentity: target.repoIdentity, color: color)
        }
    }

    private static func index(for color: String) -> Int {
        let clean = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return swatches.firstIndex { $0.name == clean } ?? 0
    }
}

public enum TrackerInlineRecolorCommand: Equatable {
    case left
    case right
    case confirm
    case cancel
}

public enum TrackerInlineRecolorEffect: Equatable {
    case preview(color: String)
    case confirm(ServeMutationRequest)
    case cancel
}

public struct TrackerInlineRecolorState: Equatable {
    private var picker: TrackerRecolorPickerState
    private let initialPreviewColor: String

    public init?(target: TrackerRecolorTarget, preferredScope: TrackerRecolorScope) {
        guard let picker = TrackerRecolorPickerState(target: target, preferredScope: preferredScope) else {
            return nil
        }
        self.picker = picker
        initialPreviewColor = picker.selectedSwatch?.name ?? ""
    }

    public var target: TrackerRecolorTarget {
        picker.target
    }

    public var scope: TrackerRecolorScope {
        picker.scope
    }

    public var previewColor: String {
        picker.selectedSwatch?.name ?? ""
    }

    public var mutationLabel: String {
        switch scope {
        case .session:
            return "recolor session \(target.sessionID)"
        case .repo:
            return "recolor repo color"
        }
    }

    public mutating func handle(_ command: TrackerInlineRecolorCommand) throws -> TrackerInlineRecolorEffect {
        switch command {
        case .left:
            picker.cycle(delta: -1)
            return .preview(color: previewColor)
        case .right:
            picker.cycle(delta: 1)
            return .preview(color: previewColor)
        case .confirm:
            return .confirm(try picker.selectedColorRequest())
        case .cancel:
            picker.selectColor(named: initialPreviewColor)
            return .cancel
        }
    }
}
