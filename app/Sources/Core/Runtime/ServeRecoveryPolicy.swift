import Foundation

public struct ServeProtocolMismatchLatch {
    private var message: String?

    public init() {}

    public var isLatched: Bool {
        message != nil
    }

    public var latchedMessage: String? {
        message
    }

    public mutating func record(_ error: ServeClientError) -> String? {
        guard error.isProtocolVersionMismatch else {
            return nil
        }
        if message == nil {
            message = error.localizedDescription
        }
        return message
    }
}

public struct ServeRespawnPolicy {
    public let maxRestarts: Int
    public let delays: [TimeInterval]
    private var restartCount = 0

    public init(maxRestarts: Int = 3, delays: [TimeInterval] = [0.5, 1.0, 2.0]) {
        self.maxRestarts = max(0, maxRestarts)
        self.delays = delays
    }

    public mutating func nextDelay() -> TimeInterval? {
        guard restartCount < maxRestarts else {
            return nil
        }
        let index = restartCount
        restartCount += 1
        guard !delays.isEmpty else {
            return 0
        }
        return delays[min(index, delays.count - 1)]
    }

    public mutating func reset() {
        restartCount = 0
    }
}
