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

/// How a shell row looks (Shell Session.svg): a simple list row, a step quieter than a plate at rest. The viewed shell
/// is the row's lasting selection and the tracker's cursor, while the tracker has the keys, fills the row too; the
/// pointer adds the hover outline to a resting row only (`RowLook.underPointer`).
public enum ShellRowStyle {
    /// The look of a row from its state. The viewed shell is `selected` (filled, bold) whether or not the cursor is
    /// on it; the cursor on another shell fills it without the bold, which only a lasting selection has.
    public static func look(viewed: Bool, cursor: Bool) -> RowLook {
        if viewed {
            return .selected
        }
        return cursor ? .highlighted : .shellRest
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
    /// glyph's disc rimmed in `item` (Shell Session.svg). A filled row takes `highlighted`'s and `selected`'s own rim.
    public static let shellRest = RowLook(fill: nil, outline: nil, text: .textMeta, meta: .textMeta, icon: .textMeta, iconBorder: .item, bold: false)
}
