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
        let targetID = cleanID(targetSessionID)
        let embeddedID = cleanOptionalID(embeddedTmuxSessionID)
        guard !disableTmux else {
            return .tmuxDisabled
        }
        guard let targetID else {
            return .tmuxDisabled
        }
        return embeddedID == targetID ? .focusAttachedTerminal : .attachEmbeddedTerminal
    }

    private static func cleanOptionalID(_ id: String?) -> String? {
        guard let id else {
            return nil
        }
        return cleanID(id)
    }

    private static func cleanID(_ id: String) -> String? {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
