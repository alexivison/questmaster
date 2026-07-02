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

    public static func currentArtifacts(
        in snapshot: TrackerSnapshot,
        preferredSessionID: String? = nil,
        scope: ArtifactScope = .session
    ) -> [ArtifactReference] {
        guard let session = currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            return []
        }
        return scopedArtifacts(in: snapshot, session: session, scope: scope)
    }

    @discardableResult
    public mutating func update(
        with snapshot: TrackerSnapshot,
        preferredSessionID: String? = nil,
        scope: ArtifactScope = .session,
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
        let artifacts = Self.scopedArtifacts(in: snapshot, session: session, scope: scope)
        let currentPaths = Set(artifacts.map(\.path))
        let previousPaths = scope == .session ? knownArtifactPathsBySessionID[session.id] : nil
        let newPaths = previousPaths.map { currentPaths.subtracting($0) } ?? []
        if scope == .session {
            knownArtifactPathsBySessionID[session.id] = currentPaths
        }

        var nextSelectedArtifactID = Self.recoveredSelection(current: selectedArtifactID, in: artifacts)

        let intent: ArtifactDisplayIntent
        if scope == .session,
           cleanPreferredSessionID == session.id,
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

    public static func movedScope(current scope: ArtifactScope, delta: Int) -> ArtifactScope {
        let scopes = ArtifactScope.allCases
        guard let currentIndex = scopes.firstIndex(of: scope) else {
            return scope
        }
        return scopes[wrapped(currentIndex + delta, count: scopes.count)]
    }

    public static func filteredArtifacts(
        _ artifacts: [ArtifactReference],
        query: String,
        projectID: String? = nil,
        typeID: String? = nil
    ) -> [ArtifactReference] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanProjectID = cleanFilterValue(projectID)
        let cleanTypeID = cleanFilterValue(typeID)
        return artifacts.filter { artifact in
            if let cleanProjectID, artifact.projectID != cleanProjectID {
                return false
            }
            if let cleanTypeID, filterTypeID(for: artifact) != cleanTypeID {
                return false
            }
            guard !cleanQuery.isEmpty else {
                return true
            }
            return artifact.label.localizedCaseInsensitiveContains(cleanQuery)
                || artifact.path.localizedCaseInsensitiveContains(cleanQuery)
                || artifact.sessionID.localizedCaseInsensitiveContains(cleanQuery)
                || artifact.projectID.localizedCaseInsensitiveContains(cleanQuery)
        }
    }

    public static func filterTypeID(for artifact: ArtifactReference) -> String {
        switch artifact.resolvedKind {
        case .html:
            return "html"
        case .markdown:
            return "markdown"
        case .image:
            return "image"
        case .unsupported:
            return "unsupported"
        }
    }

    private static func cleanFilterValue(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
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
        scope: ArtifactScope = .session,
        selectedArtifactID: String? = nil
    ) -> ArtifactViewerDisplayState {
        guard let session = Self.currentSession(in: snapshot, preferredSessionID: preferredSessionID) else {
            return .noCurrentSession
        }
        return Self.displayState(
            sessionID: session.id,
            artifacts: Self.scopedArtifacts(in: snapshot, session: session, scope: scope),
            selectedArtifactID: selectedArtifactID
        )
    }

    private static func scopedArtifacts(
        in snapshot: TrackerSnapshot,
        session: TrackerSession,
        scope: ArtifactScope
    ) -> [ArtifactReference] {
        if snapshot.artifacts.isEmpty {
            switch scope {
            case .session:
                return session.artifacts
            case .project:
                guard !session.repoIdentity.isEmpty else {
                    return []
                }
                return snapshot.repos.flatMap(\.sessions)
                    .filter { $0.repoIdentity == session.repoIdentity }
                    .flatMap(\.artifacts)
            case .all:
                return snapshot.repos.flatMap(\.sessions).flatMap(\.artifacts)
            }
        }

        switch scope {
        case .session:
            return snapshot.artifacts.filter { $0.sessionID == session.id }
        case .project:
            guard !session.repoIdentity.isEmpty else {
                return []
            }
            return snapshot.artifacts.filter { $0.projectID == session.repoIdentity }
        case .all:
            return snapshot.artifacts
        }
    }

    public static func displayState(
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
