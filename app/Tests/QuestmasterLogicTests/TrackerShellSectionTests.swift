import Foundation
import QuestmasterCore

struct TrackerShellSectionTests {
    static func run() {
        onlyPlainShellsTmuxAndOrphansAreShellRows()
        shellsLeaveTheirReposAndKeepTheirOrder()
        aRepoOfOnlyShellsHasNoPlateRows()
        thePlatesListScrollsOnlyToPlates()
        theShellScrollerSeesOnlyShells()
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

    /// A cursor on a shell is not for the plates' list: it gets no id, so it neither scrolls nor consumes the pointer's
    /// marker for a row it doesn't hold.
    private static func thePlatesListScrollsOnlyToPlates() {
        let rows = [session("m", role: "master"), session("w", role: "worker", parent: "m"), session("s", role: "shell"), session("t", role: "tmux")]
        expect(TrackerShellSection.plateCursorID("m", in: rows) == "m", "the cursor on a master goes to the plates' list")
        expect(TrackerShellSection.plateCursorID("w", in: rows) == "w", "the cursor on a worker goes to the plates' list")
        expect(TrackerShellSection.plateCursorID("s", in: rows) == nil, "the cursor on a shell is not sent to the plates' list")
        expect(TrackerShellSection.plateCursorID("t", in: rows) == nil, "nor is a tmux row")
        expect(TrackerShellSection.plateCursorID(nil, in: rows) == nil, "no cursor, no id")
        expect(TrackerShellSection.plateCursorID("gone", in: rows) == nil, "a cursor on no listed row, no id")
    }

    /// The shell section's scroller is the mirror: it sees the cursor only on its own rows, and reveals the cursor's shell,
    /// else the viewed one, when it appears or its rows change.
    private static func theShellScrollerSeesOnlyShells() {
        let rows = [session("m", role: "master"), session("s", role: "shell"), session("t", role: "tmux"), session("o", role: "orphan")]
        let shells = rows.filter(TrackerShellSection.isShellRow)
        expect(TrackerShellSection.shellCursorID("s", in: rows) == "s" && TrackerShellSection.shellCursorID("o", in: rows) == "o", "the cursor on a shell goes to the shell scroller")
        expect(TrackerShellSection.shellCursorID("m", in: rows) == nil, "the cursor on a plate is not sent to the shell scroller")
        expect(TrackerShellSection.shellCursorID(nil, in: rows) == nil && TrackerShellSection.shellCursorID("gone", in: rows) == nil, "no cursor, or an unlisted one, no id")
        for id in ["m", "s", "t", "o", "gone"] {
            expect(
                (TrackerShellSection.plateCursorID(id, in: rows) == nil) != (TrackerShellSection.shellCursorID(id, in: rows) == nil) || id == "gone",
                "a listed cursor row \(id) belongs to exactly one scroller"
            )
        }
        expect(TrackerShellSection.revealID(cursorID: "t", viewedID: "s", in: shells) == "t", "the cursor's shell is revealed first")
        expect(TrackerShellSection.revealID(cursorID: "m", viewedID: "s", in: shells) == "s", "a cursor on a plate falls back to the viewed shell")
        expect(TrackerShellSection.revealID(cursorID: nil, viewedID: "o", in: shells) == "o", "no cursor falls back to the viewed shell")
        expect(TrackerShellSection.revealID(cursorID: "m", viewedID: "m", in: shells) == nil, "neither on a shell reveals nothing")
        expect(TrackerShellSection.revealID(cursorID: "s", viewedID: nil, in: []) == nil, "no shells reveal nothing")
    }

    /// Shell Session.svg's four states: rest; the cursor alone, outlined with no fill; the viewed shell, filled and bold (the
    /// lasting selection, the only bold row); the cursor on the viewed shell, fill, bold and outline.
    private static func aShellRowTakesItsLookFromViewingAndTheCursor() {
        expect(ShellRowStyle.look(viewed: false, cursor: false) == .shellRest, "a shell nobody views or points at rests")
        expect(ShellRowStyle.look(viewed: false, cursor: true) == .shellCursor, "the cursor alone outlines a shell")
        expect(ShellRowStyle.look(viewed: true, cursor: false) == .selected, "the viewed shell is selected")
        expect(ShellRowStyle.look(viewed: true, cursor: true) == .shellSelectedCursor, "the cursor on the viewed shell adds its outline to the fill")
        let looks = [(false, false), (false, true), (true, false), (true, true)].map { ShellRowStyle.look(viewed: $0.0, cursor: $0.1) }
        expect(Set(looks.map { "\($0)" }).count == 4, "the four states look different")
        expect(looks.map(\.bold) == [false, false, true, true], "only the viewed shell is bold")
        expect(looks.map { $0.fill != nil } == [false, false, true, true], "only the viewed shell is filled")
        expect(looks.map { $0.outline != nil } == [false, true, false, true], "the cursor is the outline")
    }

    private static func theShellLooksFollowTheStateRules() {
        let rest = RowLook.shellRest
        expect(rest.fill == nil && rest.outline == nil, "a resting shell row has no fill and no outline")
        expect(rest.text == .textMeta && rest.icon == .textMeta, "its title and glyph are meta text")
        expect(rest.iconBorder == .item, "its glyph's disc has the item border")
        let hovered = rest.underPointer(true)
        expect(hovered.outline == RowLook.hovered.outline && hovered.fill == nil, "the pointer adds the hover outline to a resting shell")
        expect(hovered.text == rest.text && hovered.icon == rest.icon, "and leaves its text and glyph as at rest")

        // The cursor: a 1pt controlBorder outline inside the row with no fill, the text as at rest (the SVG's outlined row).
        let cursor = RowLook.shellCursor
        expect(cursor.fill == nil && cursor.outline == .controlBorder && !cursor.bold, "the cursor alone is a controlBorder outline, no fill, regular weight")
        expect(cursor.text == rest.text && cursor.icon == rest.icon && cursor.meta == rest.meta, "its text and glyph are as at rest")
        expect(cursor.outline != RowLook.hovered.outline, "the cursor's outline is a step above the hover's, so the two never read alike")
        expect(cursor.underPointer(true) == cursor, "the pointer leaves the cursor's outline as it is")

        // The viewed shell, alone and under the cursor: filled, bold, textSelected; the cursor adds the outline.
        let attached = RowLook.selected
        let attachedCursor = RowLook.shellSelectedCursor
        expect(attached.fill == .item && attached.outline == nil && attached.bold && attached.text == .textSelected, "the viewed shell is filled and bold")
        expect(attachedCursor.fill == .item && attachedCursor.outline == .controlBorder && attachedCursor.bold && attachedCursor.text == .textSelected,
               "the viewed shell under the cursor is filled, bold and outlined")
        for filled in [attached, attachedCursor] {
            expect(filled.underPointer(true) == filled, "the pointer adds nothing to a filled shell")
        }
        expect(rest.text.luminance < attached.text.luminance && rest.text.luminance < attachedCursor.text.luminance, "an attached shell's text is brighter than at rest")
        for look in [rest, hovered, cursor, attached, attachedCursor] {
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
