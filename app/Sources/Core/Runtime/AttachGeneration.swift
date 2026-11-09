import Foundation

/// A completion may change the terminal only while its request is still current.
public struct AttachGeneration {
    private var value: UInt64 = 0

    public init() {}

    @discardableResult public mutating func request() -> UInt64 {
        value &+= 1
        return value
    }

    public func accepts(_ request: UInt64) -> Bool {
        request == value
    }

    public mutating func stop() {
        value &+= 1
    }

    public mutating func detach() {
        value &+= 1
    }
}
