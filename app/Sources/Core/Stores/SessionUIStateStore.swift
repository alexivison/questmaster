import Foundation
import Observation

/// Observable owner of per-session dock/artifact UI state.
///
/// Holds an id-keyed map of `SessionUIState` plus the cleaned id of the
/// currently-viewed session. The restore decision and its recording-suppression window
/// are both owned here (`restoreIfActiveChanged`), so callers never manage an external
/// "is restoring" flag and the ordering invariants are unit-testable without any UI.
/// Cleanup is driven externally via `pruneSessions(keeping:)`. `@Observable` so SwiftUI
/// chrome can read it directly.
@Observable
public final class SessionUIStateStore {
    private var statesBySessionID: [String: SessionUIState]
    /// Cleaned id of the viewed session, or `nil` when none is active.
    public private(set) var activeSessionID: String?
    /// True only while `restoreIfActiveChanged` is applying restored values, so `record`
    /// does not echo the restored state back into the store.
    private var isRestoring = false

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

    /// If the viewed session changed to `id`, advances the active session, applies the
    /// stored state for that session via `apply` with recording suppressed, and returns
    /// `true`. Otherwise leaves everything untouched and returns `false` (the caller
    /// should keep recording live changes via `record`).
    ///
    /// The `guard` on an unchanged id is a correctness requirement: the caller's render
    /// path runs on many non-switch events and must not clobber an in-progress user
    /// change. Suppression is scoped to `apply` so the restored values the caller writes
    /// back to the live UI are not re-recorded as if the user had made them.
    @discardableResult
    public func restoreIfActiveChanged(to id: String?, apply: (SessionUIState) -> Void) -> Bool {
        let cleaned = cleanSessionID(id)
        guard cleaned != activeSessionID else {
            return false
        }
        activeSessionID = cleaned
        isRestoring = true
        defer { isRestoring = false }
        apply(current)
        return true
    }

    /// Records live UI state into the active session, lazily inserting `.initial` first.
    /// No-op when there is no active session, or while a restore is applying (the values
    /// being written then are the restored ones and must not be re-recorded).
    public func record(_ body: (inout SessionUIState) -> Void) {
        guard !isRestoring, let activeSessionID else {
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
