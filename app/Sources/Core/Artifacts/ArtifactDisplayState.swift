import Foundation

public enum ArtifactDisplayIntent: Equatable {
    case none
    case open(ArtifactReference)
}

public enum ArtifactViewerDisplayState: Equatable {
    case noCurrentSession
    case empty(sessionID: String)
    case missing(ArtifactReference)
    case unsupported(ArtifactReference)
    case viewing(ArtifactReference)
}

public struct ArtifactDisplayUpdate: Equatable {
    public var artifacts: [ArtifactReference]
    public var displayState: ArtifactViewerDisplayState
    public var intent: ArtifactDisplayIntent
    public var sessionChanged: Bool

    public init(
        artifacts: [ArtifactReference],
        displayState: ArtifactViewerDisplayState,
        intent: ArtifactDisplayIntent,
        sessionChanged: Bool = false
    ) {
        self.artifacts = artifacts
        self.displayState = displayState
        self.intent = intent
        self.sessionChanged = sessionChanged
    }
}

public struct ArtifactDisplayState: Equatable {
    public private(set) var currentSessionID: String?

    /// Selected artifact per session, so the open artifact survives switching sessions.
    private var selectionBySessionID: [String: String]
    private var knownArtifactPathsBySessionID: [String: Set<String>]

    /// The selected artifact for the current session (nil when there is none).
    public var selectedArtifactID: String? {
        currentSessionID.flatMap { selectionBySessionID[$0] }
    }

    public init() {
        self.currentSessionID = nil
        self.selectionBySessionID = [:]
        self.knownArtifactPathsBySessionID = [:]
    }

    private mutating func setSelection(_ artifactID: String?, for sessionID: String) {
        selectionBySessionID[sessionID] = artifactID
    }

    public static func currentSession(in snapshot: TrackerSnapshot, preferredSessionID: String? = nil) -> TrackerSession? {
        let sessions = snapshot.repos.lazy.flatMap(\.sessions)
        if let preferredSessionID = cleanSessionID(preferredSessionID),
           let preferred = sessions.first(where: { $0.id == preferredSessionID }) {
            return preferred
        }
        return sessions.first { $0.isCurrent }
    }

    public static func currentArtifacts(in snapshot: TrackerSnapshot, preferredSessionID: String? = nil) -> [ArtifactReference] {
        currentSession(in: snapshot, preferredSessionID: preferredSessionID)?.artifacts ?? []
    }

    @discardableResult
    public mutating func update(with snapshot: TrackerSnapshot, preferredSessionID: String? = nil) -> ArtifactDisplayUpdate {
        let cleanPreferredSessionID = Self.cleanSessionID(preferredSessionID)
        let previousSessionID = currentSessionID
        guard let session = Self.currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            currentSessionID = nil
            return ArtifactDisplayUpdate(
                artifacts: [],
                displayState: .noCurrentSession,
                intent: .none,
                sessionChanged: previousSessionID != nil
            )
        }

        currentSessionID = session.id
        let sessionChanged = previousSessionID != nil && previousSessionID != session.id
        let artifacts = session.artifacts
        let currentPaths = Set(artifacts.map(\.path))
        let previousPaths = knownArtifactPathsBySessionID[session.id]
        let newPaths = previousPaths.map { currentPaths.subtracting($0) } ?? []
        knownArtifactPathsBySessionID[session.id] = currentPaths

        // No reset on session change: each session keeps its own selection, recovered below.
        recoverSelection(in: artifacts)

        let intent: ArtifactDisplayIntent
        if cleanPreferredSessionID == session.id,
           previousPaths != nil,
           let newestNewArtifact = artifacts.first(where: { newPaths.contains($0.path) }) {
            setSelection(newestNewArtifact.id, for: session.id)
            intent = .open(newestNewArtifact)
        } else {
            intent = .none
        }

        return ArtifactDisplayUpdate(
            artifacts: artifacts,
            displayState: displayState(sessionID: session.id, artifacts: artifacts),
            intent: intent,
            sessionChanged: sessionChanged
        )
    }

    public mutating func select(_ artifactID: String?) {
        guard let currentSessionID else {
            return
        }
        setSelection(artifactID, for: currentSessionID)
    }

    @discardableResult
    public mutating func moveSelection(delta: Int, in artifacts: [ArtifactReference]) -> String? {
        guard let currentSessionID else {
            return nil
        }
        guard !artifacts.isEmpty else {
            setSelection(nil, for: currentSessionID)
            return nil
        }
        let currentIndex = selectedArtifactID.flatMap { id in artifacts.firstIndex { $0.id == id } } ?? 0
        let nextIndex = wrapped(currentIndex + delta, count: artifacts.count)
        let nextID = artifacts[nextIndex].id
        setSelection(nextID, for: currentSessionID)
        return nextID
    }

    public func displayState(for snapshot: TrackerSnapshot, preferredSessionID: String? = nil) -> ArtifactViewerDisplayState {
        guard let session = Self.currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            return .noCurrentSession
        }
        return displayState(sessionID: session.id, artifacts: session.artifacts)
    }

    private mutating func recoverSelection(in artifacts: [ArtifactReference]) {
        guard let currentSessionID else {
            return
        }
        guard !artifacts.isEmpty else {
            setSelection(nil, for: currentSessionID)
            return
        }
        if let selected = selectionBySessionID[currentSessionID], artifacts.contains(where: { $0.id == selected }) {
            return
        }
        setSelection(artifacts[0].id, for: currentSessionID)
    }

    private func displayState(sessionID: String, artifacts: [ArtifactReference]) -> ArtifactViewerDisplayState {
        guard !artifacts.isEmpty else {
            return .empty(sessionID: sessionID)
        }
        let selected = selectionBySessionID[sessionID]
        let artifact = selected.flatMap { id in artifacts.first { $0.id == id } } ?? artifacts[0]
        if artifact.missing {
            return .missing(artifact)
        }
        if artifact.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "html" {
            return .unsupported(artifact)
        }
        return .viewing(artifact)
    }

    private func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }

    private static func cleanSessionID(_ id: String?) -> String? {
        QuestmasterCore.cleanSessionID(id)
    }
}
