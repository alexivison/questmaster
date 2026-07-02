import Foundation

public struct BackendShimRepairDecision: Equatable {
    public let replacementContent: String?
    public let staleTargetDirectory: String?

    public var needsRewrite: Bool {
        replacementContent != nil
    }
}

public enum BackendShimRepair {
    public static func directScript(executable: String) -> String {
        "#!/bin/sh\nexec \(shellQuoted(executable)) \"$@\"\n"
    }

    public static func devScript(go: String, repoRoot: String, fallbackExecutable: String?) -> String {
        var lines = [
            "#!/bin/sh",
            "cd \(shellQuoted(repoRoot)) && exec \(shellQuoted(go)) run . \"$@\"",
        ]
        if let fallbackExecutable, !fallbackExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("exec \(shellQuoted(fallbackExecutable)) \"$@\"")
        } else {
            lines.append("echo 'questmaster dev backend worktree is unavailable' >&2")
            lines.append("exit 127")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func repairDecision(
        content: String,
        fallbackExecutable: String,
        directoryExists: (String) -> Bool
    ) -> BackendShimRepairDecision {
        guard let target = devShimTargetDirectory(in: content), !directoryExists(target) else {
            return BackendShimRepairDecision(replacementContent: nil, staleTargetDirectory: nil)
        }
        return BackendShimRepairDecision(
            replacementContent: directScript(executable: fallbackExecutable),
            staleTargetDirectory: target
        )
    }

    public static func devShimTargetDirectory(in content: String) -> String? {
        guard content.contains(" run . \"$@\"") else {
            return nil
        }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("cd ") else {
                continue
            }
            return shellWord(String(trimmed.dropFirst(3)))
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func shellWord(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let quoted = shellSingleQuotedWord(trimmed) {
            return quoted
        }
        let end = trimmed.firstIndex { $0 == " " || $0 == "\t" || $0 == ";" } ?? trimmed.endIndex
        let word = String(trimmed[..<end])
        return word.isEmpty ? nil : word
    }

    private static func shellSingleQuotedWord(_ value: String) -> String? {
        guard value.first == "'" else {
            return nil
        }
        var result = ""
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            if value[index] == "'" {
                let next = value.index(after: index)
                if next < value.endIndex,
                   value[next] == "\\" {
                    let quote = value.index(after: next)
                    if quote < value.endIndex,
                       value[quote] == "'" {
                        let reopen = value.index(after: quote)
                        if reopen < value.endIndex,
                           value[reopen] == "'" {
                            result.append("'")
                            index = value.index(after: reopen)
                            continue
                        }
                    }
                }
                return result
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return nil
    }
}
