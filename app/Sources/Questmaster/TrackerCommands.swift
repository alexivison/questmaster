import AppKit
import QuestmasterCore

struct TrackerMutationDispatch {
    let request: ServeMutationRequest?
    let label: String
    let switchToSessionID: String?
    let switchBeforeMutation: Bool
    let switchBeforeMutationIntent: TrackerActivationIntent
    let clearTerminalOnSuccess: Bool

    init(
        request: ServeMutationRequest?,
        label: String,
        switchToSessionID: String? = nil,
        switchBeforeMutation: Bool = false,
        switchBeforeMutationIntent: TrackerActivationIntent = .switchSession,
        clearTerminalOnSuccess: Bool = false
    ) {
        self.request = request
        self.label = label
        self.switchToSessionID = switchToSessionID
        self.switchBeforeMutation = switchBeforeMutation
        self.switchBeforeMutationIntent = switchBeforeMutationIntent
        self.clearTerminalOnSuccess = clearTerminalOnSuccess
    }
}

struct TrackerDeletePlan {
    let sessionID: String
    let mutation: TrackerMutationDispatch
}

enum TrackerRecolorCommandResult {
    case status(String)
    case mutation(TrackerMutationDispatch)
}

struct TrackerCommandState {
    var selectedID: String?
    var recolorEdit: TrackerInlineRecolorState?

    mutating func select(_ id: String?) {
        if recolorEdit?.target.sessionID != id {
            recolorEdit = nil
        }
        selectedID = id
    }

    func renderedSelectedID(in rows: [TrackerSession]) -> String? {
        if let selectedID, rows.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return rows.first(where: \.isCurrent)?.id ?? rows.first?.id
    }

    mutating func moveSelection(delta: Int, rows: [TrackerSession]) -> Bool {
        guard let nextID = TrackerSelection.nextSelectionID(
            currentID: renderedSelectedID(in: rows),
            sessions: rows,
            delta: delta
        ) else {
            return false
        }
        select(nextID)
        return true
    }

    func selectedSession(in rows: [TrackerSession]) -> TrackerSession? {
        TrackerActivationTarget.session(
            openedID: nil,
            selectedID: renderedSelectedID(in: rows),
            sessions: rows
        )
    }

    mutating func renderedRepos(snapshot: RuntimeSnapshot) -> [TrackerRenderedRepo] {
        var repos = TrackerRenderer.tracker(snapshot, recolorPreview: recolorEdit)
        if let recolorEdit,
           !TrackerRenderer.flatSessions(in: repos).contains(where: { $0.id == recolorEdit.target.sessionID }) {
            self.recolorEdit = nil
            repos = TrackerRenderer.tracker(snapshot)
        }
        return repos
    }

    mutating func clearStaleRecolorEdit(snapshot: RuntimeSnapshot) {
        guard let recolorEdit else {
            return
        }
        let rows = TrackerRenderer.flatSessions(in: TrackerRenderer.tracker(snapshot))
        if !rows.contains(where: { $0.id == recolorEdit.target.sessionID }) {
            self.recolorEdit = nil
        }
    }

    func deletePlan(
        rows: [TrackerSession],
        currentTerminalSessionID: String?
    ) -> TrackerDeletePlan? {
        guard let session = selectedSession(in: rows) else {
            return nil
        }
        let recoveryTarget = TrackerSelection.switchBeforeDeleteTarget(
            deleted: session,
            sessions: rows,
            currentTerminalSessionID: currentTerminalSessionID
        )
        let clearTerminalOnSuccess = recoveryTarget == nil && TrackerSelection.deleteAffectsSessionID(
            deleted: session,
            sessions: rows,
            sessionID: currentTerminalSessionID
        )
        let mutation = TrackerMutationDispatch(
            request: try? ServeMutationRequests.delete(sessionID: session.id),
            label: "delete \(session.id)",
            switchToSessionID: recoveryTarget?.sessionID,
            switchBeforeMutation: recoveryTarget != nil,
            switchBeforeMutationIntent: recoveryTarget?.intent ?? .switchSession,
            clearTerminalOnSuccess: clearTerminalOnSuccess
        )
        return TrackerDeletePlan(sessionID: session.id, mutation: mutation)
    }

    mutating func beginRecolor(
        scope: TrackerRecolorScope,
        rows: [TrackerSession]
    ) -> String? {
        guard let session = selectedSession(in: rows) else {
            return nil
        }
        let target = TrackerRecolorTarget(
            sessionID: session.id,
            role: session.role,
            repoIdentity: session.repoIdentity,
            displayColor: session.displayColor,
            repoColor: session.repoColor
        )
        guard let state = TrackerRecolorPickerState(target: target, preferredScope: scope),
              let edit = TrackerInlineRecolorState(target: state.target, preferredScope: state.scope) else {
            return "no color target for \(session.id)"
        }
        recolorEdit = edit
        selectedID = session.id
        return "\(edit.mutationLabel): \(edit.previewColor)"
    }

    mutating func applyInlineRecolorCommand(_ command: TrackerInlineRecolorCommand) -> TrackerRecolorCommandResult? {
        guard var edit = recolorEdit else {
            return nil
        }
        do {
            let effect = try edit.handle(command)
            switch effect {
            case .preview(let color):
                recolorEdit = edit
                return .status("\(edit.mutationLabel): \(color)")
            case .confirm(let request):
                let label = edit.mutationLabel
                recolorEdit = nil
                return .mutation(TrackerMutationDispatch(request: request, label: label))
            case .cancel:
                recolorEdit = nil
                return .status("recolor cancelled")
            }
        } catch {
            return .status("mutation input incomplete")
        }
    }

    func inlineRecolorCommand(for event: NSEvent) -> TrackerInlineRecolorCommand? {
        guard recolorEdit != nil else {
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return nil
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if Keymap.List.open.matches(event.keyCode) {
            return .confirm
        }
        if event.keyCode == 53 {
            return .cancel
        }
        if event.keyCode == 123 || key == "h" {
            return .left
        }
        if event.keyCode == 124 || key == "l" {
            return .right
        }
        return nil
    }
}
