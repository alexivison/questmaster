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
    public private(set) var selectedArtifactID: String?
    public private(set) var currentSessionID: String?

    private var knownArtifactPathsBySessionID: [String: Set<String>]

    public init(
        selectedArtifactID: String? = nil,
        currentSessionID: String? = nil,
        knownArtifactPathsBySessionID: [String: Set<String>] = [:]
    ) {
        self.selectedArtifactID = selectedArtifactID
        self.currentSessionID = currentSessionID
        self.knownArtifactPathsBySessionID = knownArtifactPathsBySessionID
    }

    public static func currentSession(in snapshot: TrackerSnapshot) -> TrackerSession? {
        snapshot.repos.lazy
            .flatMap(\.sessions)
            .first { $0.isCurrent }
    }

    public static func currentArtifacts(in snapshot: TrackerSnapshot) -> [ArtifactReference] {
        currentSession(in: snapshot)?.artifacts ?? []
    }

    @discardableResult
    public mutating func update(with snapshot: TrackerSnapshot) -> ArtifactDisplayUpdate {
        let previousSessionID = currentSessionID
        guard let session = Self.currentSession(in: snapshot) else {
            currentSessionID = nil
            selectedArtifactID = nil
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

        if sessionChanged {
            selectedArtifactID = nil
        }
        recoverSelection(in: artifacts)

        let intent: ArtifactDisplayIntent
        if previousPaths != nil, let newestNewArtifact = artifacts.first(where: { newPaths.contains($0.path) }) {
            selectedArtifactID = newestNewArtifact.id
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
        selectedArtifactID = artifactID
    }

    @discardableResult
    public mutating func moveSelection(delta: Int, in artifacts: [ArtifactReference]) -> String? {
        guard !artifacts.isEmpty else {
            selectedArtifactID = nil
            return nil
        }
        let currentIndex = selectedArtifactID.flatMap { id in artifacts.firstIndex { $0.id == id } } ?? 0
        let nextIndex = wrapped(currentIndex + delta, count: artifacts.count)
        selectedArtifactID = artifacts[nextIndex].id
        return selectedArtifactID
    }

    public func displayState(for snapshot: TrackerSnapshot) -> ArtifactViewerDisplayState {
        guard let session = Self.currentSession(in: snapshot) else {
            return .noCurrentSession
        }
        return displayState(sessionID: session.id, artifacts: session.artifacts)
    }

    private mutating func recoverSelection(in artifacts: [ArtifactReference]) {
        guard !artifacts.isEmpty else {
            selectedArtifactID = nil
            return
        }
        if let selectedArtifactID, artifacts.contains(where: { $0.id == selectedArtifactID }) {
            return
        }
        selectedArtifactID = artifacts[0].id
    }

    private func displayState(sessionID: String, artifacts: [ArtifactReference]) -> ArtifactViewerDisplayState {
        guard !artifacts.isEmpty else {
            return .empty(sessionID: sessionID)
        }
        let artifact = selectedArtifactID.flatMap { id in artifacts.first { $0.id == id } } ?? artifacts[0]
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
}
