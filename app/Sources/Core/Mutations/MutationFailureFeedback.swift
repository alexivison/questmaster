import Foundation

public enum MutationFailureFeedback {
    public static func message(label: String, errorDescription: String) -> String {
        let action = clean(label)
        let detail = clean(errorDescription)

        switch (action.isEmpty, detail.isEmpty) {
        case (true, true):
            return "Mutation failed."
        case (true, false):
            return "Mutation failed: \(detail)"
        case (false, true):
            return "Could not \(action)."
        case (false, false):
            return "Could not \(action): \(detail)"
        }
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
