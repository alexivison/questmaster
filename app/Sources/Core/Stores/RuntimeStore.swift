import Foundation
import Observation

/// Observable owner of the app's runtime view state.
///
/// Phase 0/2 of the architecture modernization (see `app/docs/architecture-modernization-plan.md`):
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
    public private(set) var serveConnectionState: ServeConnectionState
    public private(set) var currentTerminalSessionID: String?

    @ObservationIgnored
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    @ObservationIgnored
    private var lastSessionDefaults: UserDefaults

    public init(
        sourceLabel: String,
        currentTerminalSessionID: String? = nil,
        serveConnectionState: ServeConnectionState = .starting,
        lastSessionDefaults: UserDefaults = .standard
    ) {
        self.snapshot = RuntimeSnapshot.empty(sourceLabel: sourceLabel)
        self.serveConnectionState = serveConnectionState
        self.currentTerminalSessionID = currentTerminalSessionID
        self.lastSessionDefaults = lastSessionDefaults
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
    public func apply(_ update: RuntimeUpdate) {
        snapshot.apply(update)
        notify()
    }

    /// Updates the serve connection state, notifying observers only when the value changes.
    public func setServeConnectionState(_ state: ServeConnectionState) {
        guard serveConnectionState != state else {
            return
        }
        serveConnectionState = state
        notify()
    }

    /// Updates the foreground terminal session id, notifying observers only when it changes.
    public func setCurrentTerminalSessionID(_ id: String?) {
        LastSessionPreference.store(sessionID: id, in: lastSessionDefaults)
        guard currentTerminalSessionID != id else {
            return
        }
        currentTerminalSessionID = id
        notify()
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
