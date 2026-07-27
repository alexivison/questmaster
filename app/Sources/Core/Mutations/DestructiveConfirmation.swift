import Foundation

public enum DestructiveConfirmationAction: Equatable {
    case deleteSession
    case deleteArtifact
}

public struct DestructiveConfirmation: Equatable {
    public let action: DestructiveConfirmationAction
    public let subjectID: String
    public let title: String
    public let message: String
    public let confirmLabel: String
    public let cancelLabel: String

    public static func deleteSession(sessionID: String) -> DestructiveConfirmation {
        let cleanID = cleaned(sessionID)
        return DestructiveConfirmation(
            action: .deleteSession,
            subjectID: cleanID,
            title: "Delete session \(cleanID)?",
            message: "\(cleanID) will be lost to the void. This can't be undone.",
            confirmLabel: "Banish",
            cancelLabel: "Cancel"
        )
    }

    public static func deleteArtifact(_ artifact: ArtifactReference) -> DestructiveConfirmation {
        let path = cleaned(artifact.path)
        let label = cleaned(artifact.label)
        let subject = label.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : label
        return DestructiveConfirmation(
            action: .deleteArtifact,
            subjectID: path,
            title: "Delete artifact \(subject)?",
            message: "This removes it from the artifact list. The file stays on disk.",
            confirmLabel: "Remove",
            cancelLabel: "Cancel"
        )
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
