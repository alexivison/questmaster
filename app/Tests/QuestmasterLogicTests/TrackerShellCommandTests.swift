import Foundation
import QuestmasterCore

struct TrackerShellCommandTests {
    static func run() {
        readingCommandsStudy()
        writingCommandsInscribe()
        networkCommandsScry()
        everythingElseChannels()
        leadInsAndPipesDoNotChangeTheCommand()
        setupLinesAreSkipped()
        spawnsSummon()
        otherQuestmasterCommandsStillChannel()
        print("TrackerShellCommandTests: all tests passed")
    }

    private static func readingCommandsStudy() {
        for command in [
            "ls -la", "cat README.md", "head -n 5 f", "tail -f log", "rg foo", "grep -r x .", "find . -name x", "fd x", "tree",
            "wc -l f", "sed -n 10,20p f.go", "git status", "git status -sb", "git log --oneline", "git diff HEAD",
            "git show abc123", "git blame f.go",
        ] {
            expect(TrackerShellCommand.pose(for: command) == .studying, "\(command) should study, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    private static func writingCommandsInscribe() {
        for command in [
            "sed -i 's/a/b/' f", "mv a b", "cp a b", "mkdir -p d", "touch f", "rm f", "apply_patch", "gofmt -w f.go",
            "git add .", "git commit -m msg", "git mv a b", "git rm f", "git worktree add ../wt -b x origin/main",
            "git checkout main", "git switch -c x", "git merge origin/main", "git rebase origin/main",
        ] {
            expect(TrackerShellCommand.pose(for: command) == .inscribing, "\(command) should inscribe, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    private static func networkCommandsScry() {
        for command in [
            "curl https://example.com", "wget https://example.com/f", "gh api repos/a/b", "git fetch origin", "git pull",
            "git push origin main", "git clone https://example.com/r.git", "gh pr create --draft", "gh pr merge 3",
            "gh pr view 3", "gh pr list", "gh pr diff 3", "gh pr checks 3", "gh issue list", "gh run view 1",
            "questmaster pr watch https://example.com/pr/1", "qm pr events 1 --unread",
        ] {
            expect(TrackerShellCommand.pose(for: command) == .scrying, "\(command) should scry, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    /// A spawn summons, whether it is `questmaster` or `qm`, and whatever lead-ins, env assignments, rtk or pipe come with it.
    private static func spawnsSummon() {
        for command in [
            "questmaster spawn --title x", "qm spawn --title x", "qm spawn", "cd /repo && questmaster spawn --title x",
            "cd a && cd b && qm spawn x", "rtk questmaster spawn x", "FOO=1 questmaster spawn x", "questmaster spawn x | tee out",
        ] {
            expect(TrackerShellCommand.pose(for: command) == .summoning, "\(command) should summon, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    /// Only the spawn summons: the other questmaster commands, and a word that only begins with spawn, channel as before.
    private static func otherQuestmasterCommandsStillChannel() {
        for command in ["questmaster send master hi", "questmaster list", "qm list", "qm send qm-1 hi", "questmaster", "questmaster spawnx x"] {
            expect(TrackerShellCommand.pose(for: command) == .channelling, "\(command) should channel, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    /// Builds, tests, scripts, questmaster, and the variants the table leaves out (`gofmt -l`, plain `sed`, other git
    /// subcommands) all channel.
    private static func everythingElseChannels() {
        for command in [
            "go test ./...", "make build", "./scripts/build.sh", "questmaster send master hi", "npm test", "swift build",
            "python3 -I script.py", "python3 - <<'EOF'\nprint(1)\nEOF", "gofmt -l .", "sed s/a/b/ f", "git -C dir status",
            "", "   ", "\n",
        ] {
            expect(TrackerShellCommand.pose(for: command) == .channelling, "\(command) should channel, got \(TrackerShellCommand.pose(for: command))")
        }
    }

    /// A leading `cd dir &&`, env assignments, the rtk proxy and a pipeline's first command decide the command.
    private static func leadInsAndPipesDoNotChangeTheCommand() {
        expect(TrackerShellCommand.pose(for: "cd /repo && git status") == .studying, "a cd lead-in should be skipped")
        expect(TrackerShellCommand.pose(for: "cd a && cd b && rg x") == .studying, "several cd lead-ins should be skipped")
        expect(TrackerShellCommand.pose(for: "cd /repo && go test ./...") == .channelling, "the command after a cd should decide")
        expect(TrackerShellCommand.pose(for: "FOO=1 BAR=two rg x") == .studying, "env assignments should be skipped")
        expect(TrackerShellCommand.pose(for: "rtk git status") == .studying, "the rtk proxy should be skipped")
        expect(TrackerShellCommand.pose(for: "cat f.txt | go run ./cmd") == .studying, "a pipeline should classify by its first command")
        expect(TrackerShellCommand.pose(for: "go test ./... | tee out") == .channelling, "a pipeline should channel by its first command")
    }

    /// Lines that only prepare the shell (a cd, an export, bare env assignments, a comment, a blank line) are skipped,
    /// whether `&&`, `;` or a line break ends them.
    private static func setupLinesAreSkipped() {
        for (command, pose) in [
            ("S=/tmp/x; cat $S/f", TrackerAvatarPose.studying),
            ("F=a D=b; rm f", .inscribing),
            ("export A=1 && git log", .studying),
            ("export PATH=/x:$PATH\ngh pr view 3", .scrying),
            ("cd /repo\nrg x", .studying),
            ("\n\nls", .studying),
            ("# look first\nls", .studying),
            ("cd /repo\nS=/tmp/x\ngo test ./...", .channelling),
        ] {
            expect(TrackerShellCommand.pose(for: command) == pose, "\(command) should be \(pose), got \(TrackerShellCommand.pose(for: command))")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerShellCommandTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
