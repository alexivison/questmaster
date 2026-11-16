import Foundation

/// The pose a shell command strikes. The command's first program decides it, after any leading setup lines (`cd dir`,
/// `export ...`, a line of bare env assignments, a comment), env assignments and `rtk`: a reading command studies, a writing one inscribes
/// (git's branch moves too), a network one scries (every `gh` call and questmaster's PR commands), a spawn summons, and anything
/// else (builds, tests, scripts, other questmaster commands) channels. The table below is the whole rule.
public enum TrackerShellCommand {
    /// Keys are a program, or a program and its subcommand or flag (`git status`, `questmaster pr`, `sed -n`). The longest key
    /// that matches wins, so `sed -n` is read before `sed`.
    private static let poses: [String: TrackerAvatarPose] = [
        // Reading
        "ls": .studying, "cat": .studying, "head": .studying, "tail": .studying, "rg": .studying, "grep": .studying,
        "find": .studying, "fd": .studying, "tree": .studying, "wc": .studying, "sed -n": .studying,
        "git status": .studying, "git log": .studying, "git diff": .studying, "git show": .studying, "git blame": .studying,
        // Writing
        "sed -i": .inscribing, "mv": .inscribing, "cp": .inscribing, "mkdir": .inscribing, "touch": .inscribing,
        "rm": .inscribing, "apply_patch": .inscribing, "gofmt -w": .inscribing,
        "git add": .inscribing, "git commit": .inscribing, "git mv": .inscribing, "git rm": .inscribing,
        "git worktree": .inscribing, "git checkout": .inscribing, "git switch": .inscribing, "git merge": .inscribing,
        "git rebase": .inscribing,
        // Network: the web, git remotes, GitHub and the PR watcher
        "curl": .scrying, "wget": .scrying, "gh": .scrying,
        "git fetch": .scrying, "git pull": .scrying, "git push": .scrying, "git clone": .scrying,
        "questmaster pr": .scrying, "qm pr": .scrying,
        // Summoning: a worker is spawned while the command runs
        "questmaster spawn": .summoning, "qm spawn": .summoning,
    ]

    /// The pose a shell command strikes; channelling when the command is empty or its program isn't in the table.
    public static func pose(for command: String) -> TrackerAvatarPose {
        let words = firstCommand(of: command)
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            if let pose = poses[words.prefix(count).joined(separator: " ")] {
                return pose
            }
        }
        return .channelling
    }

    /// The first command's words: the command after any leading setup segments, cut at the first pipe, with env assignments
    /// and `rtk` dropped from its front. Segments end at `&&`, `;` and line breaks.
    static func firstCommand(of command: String) -> [String] {
        let segments = command
            .replacingOccurrences(of: ";", with: "&&")
            .replacingOccurrences(of: "\n", with: "&&")
            .components(separatedBy: "&&")
        guard let first = segments.first(where: { !isSetup($0) }) else {
            return []
        }
        var words = tokens(in: first.components(separatedBy: "|").first ?? "")
        while let word = words.first, isEnvironmentAssignment(word) || word == "rtk" {
            words.removeFirst()
        }
        return words
    }

    /// A segment that only prepares the shell: blank, a comment, a `cd`, an `export`, or nothing but env assignments (`S=/tmp/x`).
    private static func isSetup(_ segment: String) -> Bool {
        let words = tokens(in: segment)
        guard let first = words.first else {
            return true
        }
        return first.hasPrefix("#") || first == "cd" || first == "export" || words.allSatisfy(isEnvironmentAssignment)
    }

    private static func tokens(in segment: String) -> [String] {
        segment.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `NAME=value`: a name of letters, digits and underscores, then an equals sign.
    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
            return false
        }
        let name = word[..<equals]
        guard let first = name.first, !first.isNumber else {
            return false
        }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
