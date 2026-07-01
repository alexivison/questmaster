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
    public var selectedArtifactID: String?

    public init(
        artifacts: [ArtifactReference],
        displayState: ArtifactViewerDisplayState,
        intent: ArtifactDisplayIntent,
        sessionChanged: Bool = false,
        selectedArtifactID: String? = nil
    ) {
        self.artifacts = artifacts
        self.displayState = displayState
        self.intent = intent
        self.sessionChanged = sessionChanged
        self.selectedArtifactID = selectedArtifactID
    }
}

public struct ArtifactDisplayState: Equatable {
    public private(set) var currentSessionID: String?

    /// Per-session path cache used only to detect newly-added artifacts.
    private var knownArtifactPathsBySessionID: [String: Set<String>]

    public init() {
        self.currentSessionID = nil
        self.knownArtifactPathsBySessionID = [:]
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
    public mutating func update(
        with snapshot: TrackerSnapshot,
        preferredSessionID: String? = nil,
        selectedArtifactID: String? = nil
    ) -> ArtifactDisplayUpdate {
        let cleanPreferredSessionID = Self.cleanSessionID(preferredSessionID)
        let previousSessionID = currentSessionID
        guard let session = Self.currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            currentSessionID = nil
            return ArtifactDisplayUpdate(
                artifacts: [],
                displayState: .noCurrentSession,
                intent: .none,
                sessionChanged: previousSessionID != nil,
                selectedArtifactID: nil
            )
        }

        currentSessionID = session.id
        let sessionChanged = previousSessionID != nil && previousSessionID != session.id
        let artifacts = session.artifacts
        let currentPaths = Set(artifacts.map(\.path))
        let previousPaths = knownArtifactPathsBySessionID[session.id]
        let newPaths = previousPaths.map { currentPaths.subtracting($0) } ?? []
        knownArtifactPathsBySessionID[session.id] = currentPaths

        var nextSelectedArtifactID = Self.recoveredSelection(current: selectedArtifactID, in: artifacts)

        let intent: ArtifactDisplayIntent
        if cleanPreferredSessionID == session.id,
           previousPaths != nil,
           let newestNewArtifact = artifacts.first(where: { newPaths.contains($0.path) }) {
            nextSelectedArtifactID = newestNewArtifact.id
            intent = .open(newestNewArtifact)
        } else {
            intent = .none
        }

        return ArtifactDisplayUpdate(
            artifacts: artifacts,
            displayState: Self.displayState(
                sessionID: session.id,
                artifacts: artifacts,
                selectedArtifactID: nextSelectedArtifactID
            ),
            intent: intent,
            sessionChanged: sessionChanged,
            selectedArtifactID: nextSelectedArtifactID
        )
    }

    public static func recoveredSelection(current selectedArtifactID: String?, in artifacts: [ArtifactReference]) -> String? {
        guard !artifacts.isEmpty else {
            return nil
        }
        if let selectedArtifactID, artifacts.contains(where: { $0.id == selectedArtifactID }) {
            return selectedArtifactID
        }
        return artifacts[0].id
    }

    public static func movedSelection(current selectedArtifactID: String?, delta: Int, in artifacts: [ArtifactReference]) -> String? {
        guard !artifacts.isEmpty else {
            return nil
        }
        let currentIndex = selectedArtifactID.flatMap { id in artifacts.firstIndex { $0.id == id } } ?? 0
        let nextIndex = wrapped(currentIndex + delta, count: artifacts.count)
        return artifacts[nextIndex].id
    }

    /// Drops known-path cache entries for sessions no longer present, always sparing the
    /// current/viewed session because tracker data can lag the terminal session selection.
    public mutating func pruneSessions(keeping liveIDs: Set<String>, active activeID: String? = nil) {
        var spared = liveIDs
        if let currentSessionID {
            spared.insert(currentSessionID)
        }
        if let activeID = Self.cleanSessionID(activeID) {
            spared.insert(activeID)
        }
        knownArtifactPathsBySessionID = knownArtifactPathsBySessionID.filter { spared.contains($0.key) }
    }

    public func displayState(
        for snapshot: TrackerSnapshot,
        preferredSessionID: String? = nil,
        selectedArtifactID: String? = nil
    ) -> ArtifactViewerDisplayState {
        guard let session = Self.currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            return .noCurrentSession
        }
        return Self.displayState(
            sessionID: session.id,
            artifacts: session.artifacts,
            selectedArtifactID: selectedArtifactID
        )
    }

    private static func displayState(
        sessionID: String,
        artifacts: [ArtifactReference],
        selectedArtifactID: String?
    ) -> ArtifactViewerDisplayState {
        guard !artifacts.isEmpty else {
            return .empty(sessionID: sessionID)
        }
        let artifact = selectedArtifactID.flatMap { id in artifacts.first { $0.id == id } } ?? artifacts[0]
        if artifact.missing {
            return .missing(artifact)
        }
        if !artifact.resolvedKind.isRenderable {
            return .unsupported(artifact)
        }
        return .viewing(artifact)
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
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
