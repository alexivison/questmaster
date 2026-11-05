import Foundation

/// Where the app's runtime connection to the backend stands. The serve client reports it as an update; the tracker
/// draws from it.
public enum ConnectionState: Equatable {
    /// Waiting for the backend's first tracker.
    case connecting
    /// Still waiting for the first tracker past `waitingWindow`: the backend is finishing a previous operation.
    case unavailable
    /// A tracker arrived on the open connection.
    case connected
    /// The connection dropped after a tracker arrived; that tracker stays until a fresh one does.
    case reconnecting
    /// The backend speaks another protocol version (the message says which), so nothing it sends applies.
    case incompatible(String)

    /// How long the app waits for a first tracker before the backend reads as unavailable.
    public static let waitingWindow: TimeInterval = 5

    /// The wait for a first tracker, `seconds` after it began.
    public static func waiting(after seconds: TimeInterval) -> ConnectionState {
        seconds >= waitingWindow ? .unavailable : .connecting
    }

    /// No tracker has come yet, so the tracker's skeleton stands in for it.
    public var awaitsFirstTracker: Bool {
        self == .connecting || self == .unavailable
    }

    /// The tracker shown is the last one from a connection that dropped.
    public var showsLastTracker: Bool {
        self == .reconnecting
    }

    /// The message that stands in for the tracker while the backend can't be used.
    public var blockingMessage: String? {
        guard case .incompatible(let message) = self else {
            return nil
        }
        return "incompatible backend: \(message)"
    }
}

/// The serve stream's connection state from what its loop has seen: the client feeds it each event and reports
/// `state`.
public struct ConnectionStateMachine {
    public private(set) var state: ConnectionState = .connecting
    private var hasTracker = false

    public init() {}

    public var isIncompatible: Bool {
        if case .incompatible = state {
            return true
        }
        return false
    }

    /// A tracker decoded on the open connection.
    public mutating func receivedTracker() {
        state = .connected
        hasTracker = true
    }

    /// The backend's protocol version doesn't match. It stays incompatible until a tracker decodes.
    public mutating func incompatible(_ message: String) {
        state = .incompatible(message)
    }

    /// A connect failed, or the open connection closed or failed, `waited` seconds after the loop began.
    public mutating func lost(after waited: TimeInterval) {
        guard !isIncompatible else {
            return
        }
        state = hasTracker ? .reconnecting : .waiting(after: waited)
    }
}
