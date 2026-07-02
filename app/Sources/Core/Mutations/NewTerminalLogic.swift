import Foundation

public enum NewTerminalLogic {
    public static func plan(
        selectedWorktreePath: String?,
        configWorkingDirectory: String?,
        homeDirectory: String
    ) -> (cwd: String, title: String) {
        let cwd = [selectedWorktreePath, configWorkingDirectory]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? homeDirectory
        return (cwd, "Shell")
    }
}
