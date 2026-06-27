import Foundation
import Observation

/// Observable owner of per-session dock/artifact UI state.
///
/// Holds an id-keyed map of `SessionUIState` plus the cleaned id of the
/// currently-viewed session. Switching the active session does not mutate stored
/// state; recording (`updateActive`) keys off `activeSessionID`. Cleanup is driven
/// externally via `pruneSessions(keeping:)`. `@Observable` so SwiftUI chrome can
/// read it directly.
@Observable
public final class SessionUIStateStore {
    public private(set) var statesBySessionID: [String: SessionUIState]
    /// Cleaned id of the viewed session, or `nil` when none is active.
    public private(set) var activeSessionID: String?

    public init() {
        self.statesBySessionID = [:]
        self.activeSessionID = nil
    }

    /// The active session's state, or `.initial` when there is no active session
    /// (or it has no stored state yet).
    public var current: SessionUIState {
        state(for: activeSessionID)
    }

    /// Stored state for `id`, returning `.initial` for a nil/blank id or an id we
    /// have never recorded.
    public func state(for id: String?) -> SessionUIState {
        guard let cleaned = cleanSessionID(id) else {
            return .initial
        }
        return statesBySessionID[cleaned] ?? .initial
    }

    /// Sets the active session to the cleaned `id`. Returns `true` only when the
    /// cleaned id actually differs from the current one (drives restore).
    @discardableResult
    public func setActiveSession(_ id: String?) -> Bool {
        let cleaned = cleanSessionID(id)
        guard cleaned != activeSessionID else {
            return false
        }
        activeSessionID = cleaned
        return true
    }

    /// Mutates the active session's state in place, lazily inserting `.initial`
    /// first. No-op when there is no active session.
    public func updateActive(_ body: (inout SessionUIState) -> Void) {
        guard let activeSessionID else {
            return
        }
        var newStates = statesBySessionID
        var state = newStates[activeSessionID] ?? .initial
        body(&state)
        newStates[activeSessionID] = state
        statesBySessionID = newStates
    }

    /// Drops any stored state whose id is not in `liveIDs`, but always spares the
    /// active session. The active session's id may be transiently absent from the
    /// snapshot the caller derives `liveIDs` from (e.g. a freshly-attached session
    /// whose tracker entry has not landed yet), and its state may have just been
    /// recorded in the same render pass — pruning it would silently reset the
    /// viewed session's remembered dock/artifact state.
    public func pruneSessions(keeping liveIDs: Set<String>) {
        let spared = activeSessionID.map { liveIDs.union([$0]) } ?? liveIDs
        let newStates = statesBySessionID.filter { spared.contains($0.key) }
        guard newStates.count != statesBySessionID.count else {
            return
        }
        statesBySessionID = newStates
    }
}
