import Foundation

public enum TerminalSessionActivationAction: Equatable {
    case attachEmbeddedTerminal
    case focusAttachedTerminal
    case tmuxDisabled
}

public enum TerminalSessionActivationDecision {
    public static func action(
        disableTmux: Bool,
        embeddedTmuxSessionID: String?,
        targetSessionID: String
    ) -> TerminalSessionActivationAction {
        let targetID = cleanTerminalLogicID(targetSessionID)
        let embeddedID = cleanTerminalLogicID(embeddedTmuxSessionID)
        guard !disableTmux else {
            return .tmuxDisabled
        }
        guard let targetID else {
            return .tmuxDisabled
        }
        return embeddedID == targetID ? .focusAttachedTerminal : .attachEmbeddedTerminal
    }
}

public enum TerminalHostTmuxConnectionAction: Equatable {
    case createTmuxBackedSurface
    case switchEmbeddedTmuxClient
    case reconnectTerminal
}

public enum TerminalHostTmuxConnectionDecision {
    public static func action(
        disableTmux: Bool,
        embeddedTmuxSessionID: String?,
        requestedTmuxSessionID: String?
    ) -> TerminalHostTmuxConnectionAction {
        guard !disableTmux, cleanTerminalLogicID(requestedTmuxSessionID) != nil else {
            return .reconnectTerminal
        }
        return cleanTerminalLogicID(embeddedTmuxSessionID) == nil
            ? .createTmuxBackedSurface
            : .switchEmbeddedTmuxClient
    }
}

public enum TerminalStartupAttachmentDecision {
    public static func targetSessionID(
        disableTmux: Bool,
        configuredSessionID: String?,
        currentTerminalSessionID: String?,
        trackerSessions: [TrackerSession]
    ) -> String? {
        guard !disableTmux else {
            return nil
        }
        if let configuredID = cleanTerminalLogicID(configuredSessionID) {
            return configuredID
        }
        if let currentID = cleanTerminalLogicID(currentTerminalSessionID),
           trackerSessions.contains(where: { cleanTerminalLogicID($0.id) == currentID }) {
            return currentID
        }
        if let currentSession = trackerSessions.first(where: \.isCurrent),
           let currentID = cleanTerminalLogicID(currentSession.id) {
            return currentID
        }
        return trackerSessions.lazy.compactMap { cleanTerminalLogicID($0.id) }.first
    }
}

private func cleanTerminalLogicID(_ id: String?) -> String? {
    let clean = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return clean.isEmpty ? nil : clean
}
