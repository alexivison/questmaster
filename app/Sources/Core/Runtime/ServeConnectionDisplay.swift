import Foundation

public enum ServeConnectionState: Equatable {
    case starting
    case ready
    case error
}

public enum ServeConnectionStatus {
    public static func state(forProcessStatus status: String) -> ServeConnectionState? {
        let lowercased = normalized(status)
        if lowercased.contains("not found")
            || lowercased.contains("failed")
            || lowercased.contains("restart limit")
            || lowercased.contains("exited") {
            return .error
        }
        if lowercased.contains("starting") || lowercased.contains("did not become ready") {
            return .starting
        }
        if lowercased.contains("ready") || lowercased.contains("already active") {
            return .ready
        }
        return nil
    }

    public static func state(forRuntimeStatus status: String) -> ServeConnectionState? {
        let lowercased = normalized(status)
        if lowercased.contains("socket connected") {
            return .ready
        }
        if lowercased.contains("connecting")
            || lowercased.contains("reconnecting")
            || lowercased.contains("not connected")
            || lowercased.contains("socket closed") {
            return .starting
        }
        if lowercased.contains("decode failed") || lowercased.contains("protocol incompatible") {
            return .error
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
