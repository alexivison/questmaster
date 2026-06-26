import Foundation

public enum StartupTerminalSwitchGuard {
    public static func shouldSuppress(
        startupSessionID: String?,
        currentTerminalSessionID: String?,
        targetSessionID: String?,
        userInitiated: Bool,
        userSwitchHasOccurred: Bool
    ) -> Bool {
        guard !userInitiated, !userSwitchHasOccurred,
              let startupSessionID = clean(startupSessionID),
              let currentTerminalSessionID = clean(currentTerminalSessionID),
              let targetSessionID = clean(targetSessionID),
              currentTerminalSessionID == startupSessionID else {
            return false
        }
        return targetSessionID != startupSessionID
    }

    private static func clean(_ value: String?) -> String? {
        let cleanValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanValue.isEmpty ? nil : cleanValue
    }
}
