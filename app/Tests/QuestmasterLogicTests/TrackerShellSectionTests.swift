import Foundation
import QuestmasterCore

struct TrackerShellSectionTests {
    static func run() {
        onlyPlainShellsTmuxAndOrphansAreShellRows()
        shellsLeaveTheirReposAndKeepTheirOrder()
        aRepoOfOnlyShellsHasNoPlateRows()
        aShellRowTakesItsLookFromViewingAndTheCursor()
        theShellLooksFollowTheStateRules()
        aShellTitleTakesItsOwnDisplayColourOnly()
        print("TrackerShellSectionTests: all tests passed")
    }

    private static func session(_ id: String, role: String, parent: String = "", displayColor: String = "") -> TrackerSession {
        TrackerSession(id: id, title: id, repoName: "repo", displayColor: displayColor, role: role, parentID: parent)
    }

    private static func onlyPlainShellsTmuxAndOrphansAreShellRows() {
        for role in ["shell", "tmux", "orphan"] {
            expect(TrackerShellSection.isShellRow(session("s", role: role)), "a \(role) row belongs to the shell section")
        }
        expect(!TrackerShellSection.isShellRow(session("m", role: "master")), "a master keeps its plate")
        expect(!TrackerShellSection.isShellRow(session("w", role: "worker", parent: "m")), "a worker keeps its plate")
        expect(!TrackerShellSection.isShellRow(session("w", role: "worker")), "a worker whose master isn't listed keeps its plate")
    }

    /// Shells go under every master and worker, repo by repo, each repo's own order kept.
    private static func shellsLeaveTheirReposAndKeepTheirOrder() {
        let repos = [
            TrackerRepo(id: "a", name: "alpha", sessions: [
                session("a-shell-1", role: "shell"), session("a-master", role: "master"),
                session("a-worker", role: "worker", parent: "a-master"), session("a-tmux", role: "tmux"),
            ]),
            TrackerRepo(id: "b", name: "beta", sessions: [
                session("b-master", role: "master"), session("b-orphan", role: "orphan"), session("b-shell", role: "shell"),
            ]),
            TrackerRepo(id: "ungrouped", name: "ungrouped", sessions: [session("u-shell", role: "shell")]),
        ]
        let rows = TrackerShellSection.rows(in: repos)
        expect(rows.map(\.session.id) == ["a-shell-1", "a-tmux", "b-orphan", "b-shell", "u-shell"], "the shells in snapshot order: \(rows.map(\.session.id))")
        expect(rows.map(\.repoName) == ["alpha", "alpha", "beta", "beta", "ungrouped"], "each shell keeps the name of the repo it was listed under")
        expect(TrackerShellSection.plateSessions(in: repos[0]).map(\.id) == ["a-master", "a-worker"], "alpha keeps its master and worker, in order")
        expect(TrackerShellSection.plateSessions(in: repos[1]).map(\.id) == ["b-master"], "beta keeps its master")
    }

    private static func aRepoOfOnlyShellsHasNoPlateRows() {
        let repo = TrackerRepo(id: "ungrouped", name: "ungrouped", sessions: [session("s1", role: "shell"), session("s2", role: "shell")])
        expect(TrackerShellSection.plateSessions(in: repo).isEmpty, "a repo of only shells draws no plates")
        expect(TrackerShellSection.rows(in: [repo]).count == 2, "and both its shells are in the section")
        expect(TrackerShellSection.rows(in: []).isEmpty, "no repos, no shell rows")
    }

    /// The viewed shell is the lasting selection, so it is the only bold row; the cursor fills another row without
    /// the bold; the rest is quiet.
    private static func aShellRowTakesItsLookFromViewingAndTheCursor() {
        expect(ShellRowStyle.look(viewed: false, cursor: false) == .shellRest, "a shell nobody views or points at rests")
        expect(ShellRowStyle.look(viewed: true, cursor: false) == .selected, "the viewed shell is selected")
        expect(ShellRowStyle.look(viewed: true, cursor: true) == .selected, "the viewed shell stays selected under the cursor")
        expect(ShellRowStyle.look(viewed: false, cursor: true) == .highlighted, "the cursor fills another shell without the bold")
        expect(!ShellRowStyle.look(viewed: false, cursor: true).bold && ShellRowStyle.look(viewed: true, cursor: false).bold, "only the viewed shell is bold")
    }

    private static func theShellLooksFollowTheStateRules() {
        let rest = RowLook.shellRest
        expect(rest.fill == nil && rest.outline == nil, "a resting shell row has no fill and no outline")
        expect(rest.text == .textMeta && rest.icon == .textMeta, "its title and glyph are meta text")
        expect(rest.iconBorder == .item, "its glyph's disc has the item border")
        let hovered = rest.underPointer(true)
        expect(hovered.outline == RowLook.hovered.outline && hovered.fill == nil, "the pointer adds the hover outline to a resting shell")
        expect(hovered.text == rest.text && hovered.icon == rest.icon, "and leaves its text and glyph as at rest")
        for filled in [RowLook.selected, .highlighted] {
            expect(filled.fill == .item, "\(filled) is filled")
            expect(filled.underPointer(true) == filled, "the pointer adds nothing to a filled shell")
        }
        expect(rest.text.luminance < RowLook.highlighted.text.luminance && rest.text.luminance < RowLook.selected.text.luminance, "a filled shell's text is brighter than at rest")
        for look in [rest, hovered] {
            expect(look.text != .accent && look.icon != .accent && look.text != .brassActive && look.icon != .brassActive, "shell rows carry no gold or brass")
        }
    }

    private static func aShellTitleTakesItsOwnDisplayColourOnly() {
        expect(ShellRowStyle.tintName(displayColor: "green") == "green", "a shell's colour tints its title")
        expect(ShellRowStyle.tintName(displayColor: " Green ") == "Green", "the colour is trimmed")
        expect(ShellRowStyle.tintName(displayColor: "#44aa88") == "#44aa88", "a hex colour tints too")
        expect(ShellRowStyle.tintName(displayColor: "") == nil, "no colour leaves the state's own text colour")
        expect(ShellRowStyle.tintName(displayColor: "  ") == nil, "a blank colour is none")
        expect(ShellRowStyle.tintName(displayColor: "none") == nil && ShellRowStyle.tintName(displayColor: "NONE") == nil, "the none colour is none")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerShellSectionTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
