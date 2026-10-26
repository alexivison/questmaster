import Foundation

/// A shell row of the tracker's shell section, with the name of the repo it was listed under.
public struct TrackerShellRow: Equatable {
    public let session: TrackerSession
    public let repoName: String

    public init(session: TrackerSession, repoName: String) {
        self.session = session
        self.repoName = repoName
    }
}

/// Shells leave the repo groups: the masters and workers keep their plates, by repo, and every shell, tmux and orphan
/// row goes to one section under all of them, in the order the snapshot lists them. The cursor and the Cmd+N numbers
/// walk the plates, then the shell section.
public enum TrackerShellSection {
    /// A plain shell, a tmux session or an orphan: every row that isn't a master or a worker. A worker whose master
    /// isn't listed stays with its plates.
    public static func isShellRow(_ session: TrackerSession) -> Bool {
        switch SessionRoleKind(role: session.role) {
        case .shell, .tmux, .orphan:
            return true
        case .master, .worker:
            return false
        }
    }

    /// The cursor id the plates' scrolling list gets: the cursor's own while it is on a plate row, nil on a shell or on no
    /// row. The list only scrolls to plates; a shell's id would make its scroll step consume the pointer's marker (see
    /// `PointerCursor`) for a row it doesn't hold.
    public static func plateCursorID(_ cursorID: String?, in rows: [TrackerSession]) -> String? {
        rows.first { $0.id == cursorID && !isShellRow($0) }?.id
    }

    /// The cursor id the shell section's scroller gets: the mirror of `plateCursorID`, so each scroller sees only the rows it
    /// holds.
    public static func shellCursorID(_ cursorID: String?, in rows: [TrackerSession]) -> String? {
        rows.first { $0.id == cursorID && isShellRow($0) }?.id
    }

    /// The shell the section scrolls into view when it appears or its rows change: the cursor's while the cursor is on a
    /// shell (it follows the viewed session unless the user moved it), else the viewed shell. Nil when neither is a shell
    /// of the section.
    public static func revealID(cursorID: String?, viewedID: String?, in shells: [TrackerSession]) -> String? {
        let shellIDs = Set(shells.map(\.id))
        return [cursorID, viewedID].compactMap { $0 }.first { shellIDs.contains($0) }
    }

    /// The repo's masters and workers, in its order.
    public static func plateSessions(in repo: TrackerRepo) -> [TrackerSession] {
        repo.sessions.filter { !isShellRow($0) }
    }

    /// The section's rows: each repo's shells in turn, each repo's own order kept.
    public static func rows(in repos: [TrackerRepo]) -> [TrackerShellRow] {
        repos.flatMap { repo in
            repo.sessions.filter(isShellRow).map { TrackerShellRow(session: $0, repoName: repo.name) }
        }
    }
}

/// How a shell row looks (Shell Session.svg's four states): a simple list row, a step quieter than a plate at rest. The
/// viewed shell is the row's lasting selection: filled and bold. The tracker's cursor, while the tracker has the keys, is
/// an outline with no fill, so a cursor row beside a filled row stays apart in a gapless stack; on the viewed shell it adds
/// the outline to the fill. The pointer adds the thinner hover outline to a resting row only (`RowLook.underPointer`).
public enum ShellRowStyle {
    /// The look of a row from its state: rest; the cursor alone (`shellCursor`, outlined); the viewed shell (`selected`,
    /// filled and bold); the viewed shell under the cursor (`shellSelectedCursor`, both). Only the viewed shell is bold,
    /// which only a lasting selection is.
    public static func look(viewed: Bool, cursor: Bool) -> RowLook {
        switch (viewed, cursor) {
        case (true, true):
            return .shellSelectedCursor
        case (true, false):
            return .selected
        case (false, true):
            return .shellCursor
        case (false, false):
            return .shellRest
        }
    }

    /// The display colour that tints a shell's title in every state, or nil for a shell with none: its title then
    /// takes its state's own text colour. The colour is the session's own, never its repo's.
    public static func tintName(displayColor: String) -> String? {
        let name = displayColor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != NewSessionFormModel.noColorLabel else {
            return nil
        }
        return name
    }
}

extension RowLook {
    /// A shell row at rest: no fill, and the title and the glyph in meta text, a step under a plate row's body text, the
    /// glyph's disc rimmed in `item` (Shell Session.svg). A filled row takes `selected`'s own rim.
    public static let shellRest = RowLook(fill: nil, outline: nil, text: .textMeta, meta: .textMeta, icon: .textMeta, iconBorder: .item, bold: false)
    /// The tracker's cursor on a shell that isn't the viewed one: a 1pt `controlBorder` outline inside the row, no fill,
    /// the text and glyph as at rest (the SVG's outlined row).
    public static let shellCursor = RowLook(fill: nil, outline: .controlBorder, text: .textMeta, meta: .textMeta, icon: .textMeta, iconBorder: .item, bold: false)
    /// The cursor on the viewed shell: `selected`'s fill and bold, and the cursor's outline (the SVG's fourth state).
    public static let shellSelectedCursor = RowLook(
        fill: .item, outline: .controlBorder, text: .textSelected, meta: .textMetaHighlighted, icon: .textSelected, iconBorder: .controlBorder, bold: true
    )
}
