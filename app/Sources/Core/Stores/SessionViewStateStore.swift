import Foundation
import Observation

/// Observable owner of per-session dock/artifact view state.
///
/// The viewed session is supplied by callers from `RuntimeStore.currentTerminalSessionID`;
/// this store only owns the id-keyed states. User actions mutate a session directly and
/// rendering reads `state(for:)`, so no restore/record feedback loop is needed.
@Observable
public final class SessionViewStateStore {
    private var statesBySessionID: [String: SessionViewState]

    public init() {
        self.statesBySessionID = [:]
    }

    /// Stored state for `id`, returning `.initial` for a nil/blank id or an id we
    /// have never seen.
    public func state(for id: String?) -> SessionViewState {
        guard let cleaned = cleanSessionID(id) else {
            return .initial
        }
        return statesBySessionID[cleaned] ?? .initial
    }

    /// Mutates state for `id`, lazily inserting `.initial`. Nil/blank ids are ignored
    /// because there is no session key to persist under.
    public func mutate(_ id: String?, _ body: (inout SessionViewState) -> Void) {
        guard let cleaned = cleanSessionID(id) else {
            return
        }
        var newStates = statesBySessionID
        var state = newStates[cleaned] ?? .initial
        body(&state)
        newStates[cleaned] = state
        statesBySessionID = newStates
    }

    /// Drops any stored state whose id is not in `liveIDs`, but always spares the
    /// viewed session. The viewed session's id may be transiently absent from the
    /// snapshot the caller derives `liveIDs` from (e.g. a freshly-attached session
    /// whose tracker entry has not landed yet), and its state may have just been
    /// written in the same render pass.
    public func pruneSessions(keeping liveIDs: Set<String>, active activeID: String?) {
        let spared = cleanSessionID(activeID).map { liveIDs.union([$0]) } ?? liveIDs
        let newStates = statesBySessionID.filter { spared.contains($0.key) }
        guard newStates.count != statesBySessionID.count else {
            return
        }
        statesBySessionID = newStates
    }
}
