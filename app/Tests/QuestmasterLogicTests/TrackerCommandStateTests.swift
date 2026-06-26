import Foundation
import QuestmasterCore

struct TrackerCommandStateTests {
    static func run() {
        selectionMovementRecoversFromMissingSelection()
        staleSelectionRecoversToPreviousActiveRowAfterDelete()
        deletePlanSwitchesBeforeDeletingAttachedMaster()
        deletePlanClearsTerminalWhenNoRecoveryExists()
        deleteCommandEmitsConfirmationEffect()
        activationCommandEmitsTypedEffects()
        beginRecolorSelectsTargetAndReportsStatus()
        recolorCommandsEmitStatusAndMutationEffects()
        inlineRecolorPreviewsConfirmsAndCancels()
        print("TrackerCommandStateTests: all tests passed")
    }

    private static func selectionMovementRecoversFromMissingSelection() {
        let rows = [
            trackerSession(id: "one"),
            trackerSession(id: "two", isCurrent: true),
            trackerSession(id: "three"),
        ]
        var state = TrackerCommandState(selectedID: "missing")

        expect(state.renderedSelectedID(in: rows) == "two", "missing selection should recover to current row")
        expect(state.moveSelection(delta: 1, rows: rows), "move from recovered selection should succeed")
        expect(state.selectedID == "three", "move down from current row should select three")
        expect(state.moveSelection(delta: 1, rows: rows), "wrapped move should succeed")
        expect(state.selectedID == "one", "move down from last row should wrap to one")
    }

    private static func staleSelectionRecoversToPreviousActiveRowAfterDelete() {
        let previousRows = [
            trackerSession(id: "qm-previous"),
            trackerSession(id: "qm-deleted"),
            trackerSession(id: "qm-next"),
        ]
        let nextRows = [
            trackerSession(id: "qm-previous"),
            trackerSession(id: "qm-next"),
        ]
        var state = TrackerCommandState(selectedID: "qm-deleted")

        state.recoverStaleSelection(previousRows: previousRows, rows: nextRows)

        expect(state.selectedID == "qm-previous", "stale deleted selection recovered to \(String(describing: state.selectedID))")
    }

    private static func deletePlanSwitchesBeforeDeletingAttachedMaster() {
        let rows = [
            trackerSession(id: "qm-master", role: "master"),
            trackerSession(id: "qm-worker", role: "worker", parentID: "qm-master"),
            trackerSession(id: "qm-next"),
        ]
        let state = TrackerCommandState(selectedID: "qm-master")

        guard let plan = state.deletePlan(rows: rows, currentTerminalSessionID: "qm-worker") else {
            fail("delete plan was nil")
        }
        expect(plan.sessionID == "qm-master", "delete plan used \(plan.sessionID)")
        expect(plan.mutation.switchToSessionID == "qm-next", "delete should recover to next unaffected session")
        expect(plan.mutation.switchBeforeMutation, "delete should switch before deleting the attached master")
        expect(plan.mutation.switchBeforeMutationIntent == .switchSession, "active recovery should switch")
        expect(!plan.mutation.clearTerminalOnSuccess, "recovery delete should not clear terminal")
        assertRequest(plan.mutation.request, method: "delete", data: ["session_id": "qm-master"])
    }

    private static func deletePlanClearsTerminalWhenNoRecoveryExists() {
        let rows = [
            trackerSession(id: "qm-master", role: "master"),
            trackerSession(id: "qm-worker", role: "worker", parentID: "qm-master"),
        ]
        let state = TrackerCommandState(selectedID: "qm-master")

        guard let plan = state.deletePlan(rows: rows, currentTerminalSessionID: "qm-worker") else {
            fail("delete plan was nil")
        }
        expect(plan.mutation.switchToSessionID == nil, "delete should have no recovery session")
        expect(!plan.mutation.switchBeforeMutation, "delete without recovery should not switch first")
        expect(plan.mutation.clearTerminalOnSuccess, "delete of attached session without recovery should clear terminal")
        assertRequest(plan.mutation.request, method: "delete", data: ["session_id": "qm-master"])
    }

    private static func deleteCommandEmitsConfirmationEffect() {
        let rows = [
            trackerSession(id: "qm-master", role: "master"),
            trackerSession(id: "qm-worker", role: "worker", parentID: "qm-master"),
            trackerSession(id: "qm-next"),
        ]
        var state = TrackerCommandState(selectedID: "qm-master")

        guard let effects = state.effects(
            for: .deleteSelected,
            rows: rows,
            currentTerminalSessionID: "qm-worker"
        ) else {
            fail("delete command produced no effects")
        }
        guard case .confirmDeleteThenMutation(let plan) = onlyEffect(effects) else {
            fail("delete command did not request confirmation: \(effects)")
        }
        expect(plan.sessionID == "qm-master", "delete confirmation used \(plan.sessionID)")
        expect(plan.mutation.switchBeforeMutation, "delete effect should keep switch-before-mutation plan")
        expect(plan.mutation.switchToSessionID == "qm-next", "delete effect should recover to next session")
    }

    private static func activationCommandEmitsTypedEffects() {
        var focusState = TrackerCommandState(selectedID: "qm-current")
        let focusRows = [
            trackerSession(id: "qm-current", isCurrent: true),
        ]
        guard let focusEffects = focusState.effects(
            for: .activate(openedID: nil),
            rows: focusRows,
            currentTerminalSessionID: "qm-current"
        ) else {
            fail("focus activation produced no effects")
        }
        guard case .focusCurrentTerminal = onlyEffect(focusEffects) else {
            fail("focus activation effect was \(focusEffects)")
        }

        var switchState = TrackerCommandState(selectedID: "qm-next")
        let switchRows = [
            trackerSession(id: "qm-current", isCurrent: true),
            trackerSession(id: "qm-next"),
        ]
        guard let switchEffects = switchState.effects(
            for: .activate(openedID: nil),
            rows: switchRows,
            currentTerminalSessionID: "qm-current"
        ) else {
            fail("switch activation produced no effects")
        }
        guard case .switchSession(let sessionID) = onlyEffect(switchEffects) else {
            fail("switch activation effect was \(switchEffects)")
        }
        expect(sessionID == "qm-next", "switch activation targeted \(sessionID)")

        var continueState = TrackerCommandState(selectedID: "qm-stopped")
        let continueRows = [
            trackerSession(id: "qm-stopped", state: "stopped", lifecycle: "stopped"),
        ]
        guard let continueEffects = continueState.effects(
            for: .activate(openedID: nil),
            rows: continueRows,
            currentTerminalSessionID: nil
        ) else {
            fail("continue activation produced no effects")
        }
        expect(continueEffects.count == 2, "continue activation effect count was \(continueEffects.count)")
        guard case .continueSession(let mutation) = continueEffects[0] else {
            fail("continue activation first effect was \(continueEffects)")
        }
        expect(mutation.label == "continue qm-stopped", "continue label was \(mutation.label)")
        expect(mutation.switchToSessionID == "qm-stopped", "continue should switch to resumed session")
        assertRequest(mutation.request, method: "continue", data: ["session_id": "qm-stopped"])
        guard case .focusCurrentTerminal = continueEffects[1] else {
            fail("continue activation second effect was \(continueEffects)")
        }
    }

    private static func beginRecolorSelectsTargetAndReportsStatus() {
        let rows = [
            trackerSession(id: "qm-one", displayColor: "magenta", repoColor: "green"),
            trackerSession(id: "qm-two"),
        ]
        var state = TrackerCommandState(selectedID: "qm-one")

        let status = state.beginRecolor(scope: .session, rows: rows)

        expect(status == "recolor session qm-one: magenta", "begin recolor status was \(String(describing: status))")
        expect(state.selectedID == "qm-one", "begin recolor should keep selected target")
        expect(state.recolorEdit?.target.sessionID == "qm-one", "begin recolor should install inline edit")
        expect(state.recolorEdit?.previewColor == "magenta", "begin recolor should preview current session color")
    }

    private static func recolorCommandsEmitStatusAndMutationEffects() {
        let rows = [
            trackerSession(id: "qm-one", repoIdentity: "/repo/.git", displayColor: "magenta", repoColor: "green"),
        ]
        var state = TrackerCommandState(selectedID: "qm-one")

        guard let beginEffects = state.effects(
            for: .beginRecolor(.session),
            rows: rows,
            currentTerminalSessionID: nil
        ) else {
            fail("begin recolor produced no effects")
        }
        guard case .showStatus(let beginStatus) = onlyEffect(beginEffects) else {
            fail("begin recolor effect was \(beginEffects)")
        }
        expect(beginStatus == "recolor session qm-one: magenta", "begin status was \(beginStatus)")

        guard let previewEffects = state.effects(
            for: .applyInlineRecolor(.right),
            rows: rows,
            currentTerminalSessionID: nil
        ) else {
            fail("preview recolor produced no effects")
        }
        guard case .showStatus(let previewStatus) = onlyEffect(previewEffects) else {
            fail("preview recolor effect was \(previewEffects)")
        }
        expect(previewStatus == "recolor session qm-one: cyan", "preview status was \(previewStatus)")

        guard let confirmEffects = state.effects(
            for: .applyInlineRecolor(.confirm),
            rows: rows,
            currentTerminalSessionID: nil
        ) else {
            fail("confirm recolor produced no effects")
        }
        guard case .sendMutation(let mutation) = onlyEffect(confirmEffects) else {
            fail("confirm recolor effect was \(confirmEffects)")
        }
        expect(mutation.label == "recolor session qm-one", "confirm label was \(mutation.label)")
        assertRequest(mutation.request, method: "recolor", data: [
            "scope": "session",
            "session_id": "qm-one",
            "color": "cyan",
        ])
    }

    private static func inlineRecolorPreviewsConfirmsAndCancels() {
        let rows = [
            trackerSession(id: "qm-one", repoIdentity: "/repo/.git", displayColor: "magenta", repoColor: "green"),
        ]
        var state = TrackerCommandState(selectedID: "qm-one")
        _ = state.beginRecolor(scope: .session, rows: rows)

        guard case .status(let preview)? = state.applyInlineRecolorCommand(.right) else {
            fail("right did not produce preview status")
        }
        expect(preview == "recolor session qm-one: cyan", "right preview status was \(preview)")
        expect(state.recolorEdit?.previewColor == "cyan", "right should update preview color")

        guard case .mutation(let mutation)? = state.applyInlineRecolorCommand(.confirm) else {
            fail("confirm did not produce mutation")
        }
        expect(state.recolorEdit == nil, "confirm should clear inline edit")
        expect(mutation.label == "recolor session qm-one", "confirm label was \(mutation.label)")
        assertRequest(mutation.request, method: "recolor", data: [
            "scope": "session",
            "session_id": "qm-one",
            "color": "cyan",
        ])

        _ = state.beginRecolor(scope: .repo, rows: rows)
        guard case .status(let cancel)? = state.applyInlineRecolorCommand(.cancel) else {
            fail("cancel did not produce status")
        }
        expect(cancel == "recolor cancelled", "cancel status was \(cancel)")
        expect(state.recolorEdit == nil, "cancel should clear inline edit")
    }

    private static func trackerSession(
        id: String,
        repoIdentity: String = "/repo/.git",
        displayColor: String = "",
        repoColor: String = "",
        role: String = "standalone",
        state: String = "idle",
        lifecycle: String = "active",
        parentID: String = "",
        isCurrent: Bool = false
    ) -> TrackerSession {
        TrackerSession(
            id: id,
            title: id,
            repoIdentity: repoIdentity,
            repoName: "repo",
            repoColor: repoColor,
            displayColor: displayColor,
            role: role,
            state: state,
            lifecycle: lifecycle,
            parentID: parentID,
            isCurrent: isCurrent
        )
    }

    private static func assertRequest(
        _ request: ServeMutationRequest?,
        method: String,
        data: [String: String]
    ) {
        guard let request else {
            fail("request was nil")
        }
        expect(request.method == method, "method was \(request.method), want \(method)")
        expect(request.data == data, "data was \(request.data), want \(data)")
    }

    private static func onlyEffect(_ effects: [TrackerEffect]) -> TrackerEffect {
        expect(effects.count == 1, "effect count was \(effects.count)")
        return effects[0]
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCommandStateTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
