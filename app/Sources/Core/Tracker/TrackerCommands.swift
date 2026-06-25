import Foundation

public struct TrackerMutationDispatch: Equatable {
    public let request: ServeMutationRequest?
    public let label: String
    public let switchToSessionID: String?
    public let switchBeforeMutation: Bool
    public let switchBeforeMutationIntent: TrackerActivationIntent
    public let clearTerminalOnSuccess: Bool

    public init(
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

public struct TrackerDeletePlan: Equatable {
    public let sessionID: String
    public let mutation: TrackerMutationDispatch

    public init(sessionID: String, mutation: TrackerMutationDispatch) {
        self.sessionID = sessionID
        self.mutation = mutation
    }
}

public enum TrackerRecolorCommandResult: Equatable {
    case status(String)
    case mutation(TrackerMutationDispatch)
}

public enum TrackerCommand: Equatable {
    case activate(openedID: String?)
    case deleteSelected
    case beginRecolor(TrackerRecolorScope)
    case applyInlineRecolor(TrackerInlineRecolorCommand)
    case jumpToNextAttention
}

public enum TrackerEffect: Equatable {
    case sendMutation(TrackerMutationDispatch)
    case confirmDeleteThenMutation(TrackerDeletePlan)
    case continueSession(TrackerMutationDispatch)
    case switchSession(String)
    case focusCurrentTerminal
    case focusTracker
    case focusDirection(NavigationDirection)
    case showStatus(String)
}

public struct TrackerCommandState: Equatable {
    public var selectedID: String?
    public var recolorEdit: TrackerInlineRecolorState?

    public init(selectedID: String? = nil, recolorEdit: TrackerInlineRecolorState? = nil) {
        self.selectedID = selectedID
        self.recolorEdit = recolorEdit
    }

    public mutating func select(_ id: String?) {
        if recolorEdit?.target.sessionID != id {
            recolorEdit = nil
        }
        selectedID = id
    }

    public func renderedSelectedID(in rows: [TrackerSession]) -> String? {
        if let selectedID, rows.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return rows.first(where: \.isCurrent)?.id ?? rows.first?.id
    }

    public mutating func moveSelection(delta: Int, rows: [TrackerSession]) -> Bool {
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

    public func selectedSession(in rows: [TrackerSession]) -> TrackerSession? {
        TrackerActivationTarget.session(
            openedID: nil,
            selectedID: renderedSelectedID(in: rows),
            sessions: rows
        )
    }

    public mutating func effects(
        for command: TrackerCommand,
        rows: [TrackerSession],
        currentTerminalSessionID: String?
    ) -> [TrackerEffect]? {
        switch command {
        case .activate(let openedID):
            return activationEffects(
                openedID: openedID,
                rows: rows,
                currentTerminalSessionID: currentTerminalSessionID
            )
        case .deleteSelected:
            guard let plan = deletePlan(
                rows: rows,
                currentTerminalSessionID: currentTerminalSessionID
            ) else {
                return nil
            }
            return [.confirmDeleteThenMutation(plan)]
        case .beginRecolor(let scope):
            guard let status = beginRecolor(scope: scope, rows: rows) else {
                return nil
            }
            return [.showStatus(status)]
        case .applyInlineRecolor(let command):
            guard let result = applyInlineRecolorCommand(command) else {
                return nil
            }
            switch result {
            case .status(let status):
                return [.showStatus(status)]
            case .mutation(let mutation):
                return [.sendMutation(mutation)]
            }
        case .jumpToNextAttention:
            if let nextID = TrackerSelection.nextNeedsInputID(currentID: selectedID, sessions: rows) {
                select(nextID)
                return [.showStatus("needs input: \(nextID)")]
            }
            return [.showStatus("no needs-input sessions")]
        }
    }

    public mutating func clearStaleRecolorEdit(rows: [TrackerSession]) {
        guard let recolorEdit,
              !rows.contains(where: { $0.id == recolorEdit.target.sessionID }) else {
            return
        }
        self.recolorEdit = nil
    }

    public mutating func recoverStaleSelection(previousRows: [TrackerSession], rows: [TrackerSession]) {
        guard let selectedID,
              !rows.contains(where: { $0.id == selectedID }) else {
            return
        }
        guard let deleted = previousRows.first(where: { $0.id == selectedID }),
              let recoveryID = TrackerSelection.nextActiveAfterDeleteID(deleted: deleted, sessions: previousRows),
              rows.contains(where: { $0.id == recoveryID }) else {
            select(renderedSelectedID(in: rows))
            return
        }
        select(recoveryID)
    }

    public func deletePlan(
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

    public mutating func beginRecolor(
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

    public mutating func applyInlineRecolorCommand(_ command: TrackerInlineRecolorCommand) -> TrackerRecolorCommandResult? {
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

    private func activationEffects(
        openedID: String?,
        rows: [TrackerSession],
        currentTerminalSessionID: String?
    ) -> [TrackerEffect]? {
        guard let session = TrackerActivationTarget.session(
            openedID: openedID,
            selectedID: renderedSelectedID(in: rows),
            sessions: rows
        ) else {
            return nil
        }
        switch TrackerActivationDecision.action(
            for: session,
            currentTerminalSessionID: currentTerminalSessionID,
            sessionIsCurrent: session.isCurrent
        ) {
        case .focusCurrentSession:
            return [.focusCurrentTerminal]
        case .continueSession:
            return [
                .continueSession(
                    TrackerMutationDispatch(
                        request: try? ServeMutationRequests.`continue`(sessionID: session.id),
                        label: "continue \(session.id)",
                        switchToSessionID: session.id
                    )
                ),
                .focusCurrentTerminal,
            ]
        case .switchSession:
            return [.switchSession(session.id)]
        }
    }
}
