import Foundation

public enum ServeConnectionState: Equatable {
    case starting
    case ready
    case error
}

public enum ServePillIndicator: Equatable {
    case dot
    case spinner
}

public enum ServePillTone: Equatable {
    case ready
    case starting
    case error
}

public struct ServePillDisplay: Equatable {
    public let label: String
    public let indicator: ServePillIndicator
    public let tone: ServePillTone

    public init(label: String, indicator: ServePillIndicator, tone: ServePillTone) {
        self.label = label
        self.indicator = indicator
        self.tone = tone
    }

    public static func display(for state: ServeConnectionState) -> ServePillDisplay {
        switch state {
        case .ready:
            return ServePillDisplay(label: "serve", indicator: .dot, tone: .ready)
        case .starting:
            return ServePillDisplay(label: "starting serve…", indicator: .spinner, tone: .starting)
        case .error:
            return ServePillDisplay(label: "serve error", indicator: .dot, tone: .error)
        }
    }
}

public enum ServeConnectionStatus {
    public static func state(forProcessStatus status: String) -> ServeConnectionState? {
        let lowercased = normalized(status)
        if lowercased.contains("not found")
            || lowercased.contains("failed")
            || lowercased.contains("did not become ready")
            || lowercased.contains("exited") {
            return .error
        }
        if lowercased.contains("starting") {
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
