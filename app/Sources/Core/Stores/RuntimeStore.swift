import Foundation
import Observation

/// Observable owner of the app's runtime view state.
///
/// Phase 0/2 of the architecture modernization:
/// state that previously lived as stored properties on `AppDelegate` moves here, so views can read
/// from a single source of truth and observe changes instead of `AppDelegate` pushing into each
/// view.
///
/// The store is `@Observable` for SwiftUI consumers (Phase 2+) and *also* exposes a manual
/// `observe(_:)` closure for the AppKit views that have not been ported yet. Both paths fire on the
/// same mutations, so AppKit and SwiftUI panes can coexist during the migration.
///
/// The store is not thread-safe; callers mutate and observe it on the main thread.
@Observable
public final class RuntimeStore {
    public private(set) var snapshot: RuntimeSnapshot
    public private(set) var currentTerminalSessionID: String?
    /// Master session IDs whose worker rows are collapsed in the tracker. Lives here (rather
    /// than as view-local `@State`) so both the SwiftUI tracker's badge numbering and
    /// AppDelegate's Cmd+1..9 lookup (`TrackerSessionShortcuts`) resolve "row N" from the same
    /// collapse-aware session list.
    public private(set) var collapsedMasterIDs: Set<String>

    @ObservationIgnored
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    public init(
        sourceLabel: String,
        currentTerminalSessionID: String? = nil,
        collapsedMasterIDs: Set<String> = []
    ) {
        self.snapshot = RuntimeSnapshot.empty(sourceLabel: sourceLabel)
        self.currentTerminalSessionID = currentTerminalSessionID
        self.collapsedMasterIDs = collapsedMasterIDs
    }

    public var quests: [QuestItem] {
        snapshot.tracker.quests
    }

    /// Registers a change observer. The returned token unsubscribes on `cancel()` or when it is
    /// released, so observers should retain the token for as long as they want notifications.
    public func observe(_ block: @escaping () -> Void) -> RuntimeStoreObservation {
        let token = RuntimeStoreObservation(store: self)
        observers[ObjectIdentifier(token)] = block
        return token
    }

    func removeObserver(_ token: RuntimeStoreObservation) {
        observers.removeValue(forKey: ObjectIdentifier(token))
    }

    /// Merges a runtime update into the snapshot and notifies observers.
    /// A no-op update (identical payload) notifies nobody.
    public func apply(_ update: RuntimeUpdate) {
        guard snapshot.apply(update) else {
            return
        }
        notify()
    }

    /// Updates the foreground terminal session id, notifying observers only when it changes.
    public func setCurrentTerminalSessionID(_ id: String?) {
        guard currentTerminalSessionID != id else {
            return
        }
        currentTerminalSessionID = id
        notify()
    }

    /// Toggles whether a master session's worker rows are collapsed.
    public func toggleWorkersCollapsed(for sessionID: String) {
        if collapsedMasterIDs.contains(sessionID) {
            collapsedMasterIDs.remove(sessionID)
        } else {
            collapsedMasterIDs.insert(sessionID)
        }
        notify()
    }

    /// Collapses every given master session's worker rows in one step (vs. toggleWorkersCollapsed's per-session toggle).
    public func collapseAllWorkers(masterIDs: [String]) {
        let updated = collapsedMasterIDs.union(masterIDs)
        guard updated != collapsedMasterIDs else {
            return
        }
        collapsedMasterIDs = updated
        notify()
    }

    /// Removes an artifact after its serve mutation acknowledges success; the next serve snapshot remains authoritative.
    public func removeArtifact(_ artifact: ArtifactReference) {
        var tracker = snapshot.tracker
        let matches: (ArtifactReference) -> Bool = { $0.path == artifact.path && $0.sessionID == artifact.sessionID }
        tracker.artifacts.removeAll(where: matches)
        for repoIndex in tracker.repos.indices {
            for sessionIndex in tracker.repos[repoIndex].sessions.indices {
                tracker.repos[repoIndex].sessions[sessionIndex].artifacts.removeAll(where: matches)
            }
        }
        apply(RuntimeUpdate(tracker: tracker))
    }

    /// Removes a quest after its serve mutation acknowledges success; the next serve snapshot remains authoritative.
    public func removeQuest(id: String) {
        var tracker = snapshot.tracker
        tracker.quests.removeAll { $0.id == id }
        apply(RuntimeUpdate(tracker: tracker))
    }

    private func notify() {
        // Snapshot the observers so a notification that mutates the store (adding or removing an
        // observer) does not invalidate the iteration.
        for block in Array(observers.values) {
            block()
        }
    }
}

/// Token returned by `RuntimeStore.observe(_:)`. Unsubscribes automatically when released.
public final class RuntimeStoreObservation {
    private weak var store: RuntimeStore?

    init(store: RuntimeStore) {
        self.store = store
    }

    public func cancel() {
        store?.removeObserver(self)
        store = nil
    }

    deinit {
        cancel()
    }
}
