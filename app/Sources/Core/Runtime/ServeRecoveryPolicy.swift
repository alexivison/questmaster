import Foundation

public struct ServeRespawnPolicy {
    public let maxRestarts: Int
    public let delays: [TimeInterval]
    private var restartCount = 0
    private var retryAfter: Date?
    private var cooldown: TimeInterval = 30

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

    public mutating func canAttempt(now: Date, userInitiated: Bool = false) -> Bool {
        guard let retryAfter else { return true }
        guard userInitiated || now >= retryAfter else { return false }
        self.retryAfter = nil
        restartCount = 0
        return true
    }

    public mutating func coolDown(after now: Date) {
        retryAfter = now.addingTimeInterval(cooldown)
        cooldown = min(cooldown * 2, 300)
    }

    public mutating func reset() {
        restartCount = 0
        retryAfter = nil
        cooldown = 30
    }
}
