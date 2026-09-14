import Foundation
import QuestmasterCore

struct RoleDefaultsLogicTests {
    static func run() {
        rowsCoverEveryAgentAndRoleInOrder()
        modelSelectStartsUnconfiguredAndTakesResolvedOptions()
        effortSelectStartsUnconfiguredAndTakesResolvedOptions()
        modelSelectSeedsOntoAPersistedDefaultOnFirstResolveOnly()
        effortSelectSeedsOntoAPersistedDefaultOnFirstResolveOnly()
        configuredRowCanNeverCycleBackToNotConfigured()
        rowDirtyTrackingReflectsUnsavedChanges()
        markSavedBaselinesOnSentValuesNotTheLiveSelection()
        settingRowOptionsOnlyAffectsThatRow()
        focusNavigationStaysWithinTheActiveTab()
        moveTabSwitchesAgentAndResetsFocus()
        cyclingFocusedValueAffectsOnlyTheFocusedField()
        print("RoleDefaultsLogicTests: all tests passed")
    }

    private static func rowsCoverEveryAgentAndRoleInOrder() {
        let model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(model.rows.count == 6, "2 agents x 3 roles should produce 6 rows, got \(model.rows.count)")
        expect(
            model.rows.map { "\($0.agent):\($0.role)" } ==
                ["claude:master", "claude:standalone", "claude:worker", "codex:master", "codex:standalone", "codex:worker"],
            "rows should be agent-major, master-then-standalone-then-worker: \(model.rows)"
        )
        expect(model.index(agent: "codex", role: "master") == 3, "index should locate the matching row")
        expect(model.index(agent: "pi", role: "worker") == nil, "index should return nil for an agent not in the model")
    }

    private static func modelSelectStartsUnconfiguredAndTakesResolvedOptions() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        expect(row.selectedModelOption == nil, "a fresh row should start with nothing selected")
        expect(row.selectedModel.isEmpty, "an unconfigured row should send no override")

        row.setModelOptions(
            [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "claude-opus-9-unreleased", label: "claude-opus-9-unreleased", note: "recent"),
            ],
            defaultModel: ""
        )
        expect(row.modelOptions.count == 2, "resolved models should be exactly the concrete options given")
        expect(row.selectedModelOption == nil, "resolving with no persisted default should leave nothing selected")

        row.cycleModel(1)
        expect(row.selectedModel == "opus", "cycling right should select the first resolved model")
        row.cycleModel(1)
        expect(row.selectedModel == "claude-opus-9-unreleased", "cycling right again should reach the next model")
        row.cycleModel(-1)
        row.cycleModel(-1)
        expect(row.selectedModel.isEmpty, "cycling back past the first entry should wrap to nothing selected")
    }

    private static func effortSelectStartsUnconfiguredAndTakesResolvedOptions() {
        var row = RoleDefaultRow(agent: "codex", role: "master")
        row.setEffortOptions(["minimal", "low", "medium", "high", "xhigh"], defaultLevel: "")
        expect(row.effortOptions.count == 5, "every supported level should be a plain, unfiltered option")
        expect(row.selectedEffortOption == nil, "resolving with no persisted default should leave nothing selected")

        row.cycleEffort(1)
        expect(row.selectedReasoningEffort == "minimal", "cycling should select the first resolved level")
        row.cycleEffort(-1)
        expect(row.selectedReasoningEffort.isEmpty, "cycling back should return to nothing selected")
    }

    // Guards the Settings "confirm silently clears an unconfigured row" fix:
    // a row must open already-selected on a persisted default, not on a
    // placeholder — the value shown in the picker IS the default.
    private static func modelSelectSeedsOntoAPersistedDefaultOnFirstResolveOnly() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        row.setModelOptions(
            [SessionModelOption(id: "opus", label: "opus"), SessionModelOption(id: "claude-opus-9-unreleased", label: "claude-opus-9-unreleased")],
            defaultModel: "claude-opus-9-unreleased"
        )
        expect(row.selectedModel == "claude-opus-9-unreleased", "a persisted default should seed the selection on first resolve")

        // A later re-resolve (e.g. a background refresh) must preserve the
        // selection the user is now looking at rather than re-seed — seeding
        // is a first-resolve-only thing. Here the new list no longer offers
        // the previously-selected id, so the selection falls back to nothing.
        row.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "claude-opus-9-unreleased")
        expect(row.selectedModelOption == nil, "a re-resolve must not re-seed once the list no longer offers the previous selection")

        var untouched = RoleDefaultRow(agent: "claude", role: "worker")
        untouched.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        expect(untouched.selectedModelOption == nil, "a default id missing from the resolved list must not be treated as selected")
    }

    private static func effortSelectSeedsOntoAPersistedDefaultOnFirstResolveOnly() {
        var row = RoleDefaultRow(agent: "codex", role: "master")
        row.setEffortOptions(["minimal", "low", "medium", "high", "xhigh"], defaultLevel: "high")
        expect(row.selectedReasoningEffort == "high", "a persisted default should seed the selection on first resolve")
        expect(row.effortOptions.filter { $0.id == "high" }.count == 1, "levels are never filtered or deduped against the default")

        var untouched = RoleDefaultRow(agent: "codex", role: "master")
        untouched.setEffortOptions(["minimal", "low", "medium", "high", "xhigh"], defaultLevel: "")
        expect(untouched.selectedEffortOption == nil, "with no persisted default, resolving should leave nothing selected")
    }

    // Guards the store's one-way contract: role_default.set never clears an
    // existing entry, so a row that starts configured must never be able to
    // cycle its way back to "not configured" — there would be nothing
    // meaningful to send if it did.
    private static func configuredRowCanNeverCycleBackToNotConfigured() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        row.setModelOptions(
            [SessionModelOption(id: "opus", label: "opus"), SessionModelOption(id: "sonnet", label: "sonnet")],
            defaultModel: "opus"
        )
        expect(row.selectedModel == "opus", "sanity: seeded onto the persisted default")

        for _ in 0..<6 {
            row.cycleModel(1)
            expect(!row.selectedModel.isEmpty, "a configured row must never cycle to nothing selected: \(row.selectedModel)")
        }
        for _ in 0..<6 {
            row.cycleModel(-1)
            expect(!row.selectedModel.isEmpty, "a configured row must never cycle to nothing selected: \(row.selectedModel)")
        }
    }

    private static func rowDirtyTrackingReflectsUnsavedChanges() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        row.setModelOptions(
            [SessionModelOption(id: "opus", label: "opus"), SessionModelOption(id: "sonnet", label: "sonnet")],
            defaultModel: "opus"
        )
        row.setEffortOptions(["low", "high"], defaultLevel: "high")
        expect(!row.isDirty, "a row that just resolved onto its persisted values is not dirty")

        row.cycleEffort(1)
        expect(row.isEffortDirty && row.isDirty, "changing the effort selection should mark the row dirty")
        expect(!row.isModelDirty, "the model field itself did not change")

        row.markSaved(model: row.selectedModel, reasoningEffort: row.selectedReasoningEffort)
        expect(!row.isDirty, "markSaved should reset the baseline once a save actually lands")

        row.cycleModel(1)
        expect(row.isModelDirty && row.isDirty, "changing the model after a save should register as newly dirty")
    }

    // Guards a real bug: the user can keep editing while a role_default.set
    // save is still in flight. markSaved must baseline onto the values that
    // were actually sent, not the row's current live selection — otherwise a
    // newer, never-sent edit gets silently stamped "already saved" the
    // instant an earlier save's ack arrives, and is then lost when the sheet
    // dismisses without ever resending it.
    private static func markSavedBaselinesOnSentValuesNotTheLiveSelection() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        row.setModelOptions(
            [SessionModelOption(id: "opus", label: "opus"), SessionModelOption(id: "sonnet", label: "sonnet")],
            defaultModel: "opus"
        )
        let sentModel = row.selectedModel
        expect(sentModel == "opus", "sanity: opus is what a confirm() at this point would have sent")

        // The user cycles again before that send's ack arrives.
        row.cycleModel(1)
        expect(row.selectedModel == "sonnet", "sanity: the row now shows a newer, unsent choice")

        // The in-flight save for the *old* value ("opus") now completes.
        row.markSaved(model: sentModel, reasoningEffort: row.selectedReasoningEffort)

        expect(row.isModelDirty && row.isDirty, "the newer edit must still read as dirty so it gets sent, not silently dropped")
        expect(row.selectedModel == "sonnet", "the newer edit itself must be untouched by the stale save's completion")
    }

    private static func settingRowOptionsOnlyAffectsThatRow() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet", agent: "claude", role: "master")
        model.cycleFocusedValue(1)
        expect(model.rows[0].selectedModel == "opus", "cycling the focused field should select its resolved model")
        expect(model.rows[1].selectedModelOption == nil, "an unrelated row must not be affected")
        expect(model.rows[2].modelOptions.isEmpty, "a different (agent, role) row must not receive another row's options")
    }

    private static func focusNavigationStaysWithinTheActiveTab() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(
            model.selectedAgentIndex == 0 && model.focusedRoleIndex == 0 && model.focusedField == .model,
            "focus should start on the first tab's master-model field"
        )

        model.moveFocus(1)
        expect(model.focusedRoleIndex == 0 && model.focusedField == .effort, "moveFocus(1) should advance to the master-effort field")

        model.moveFocus(1)
        expect(model.focusedRoleIndex == 1 && model.focusedField == .model, "moveFocus(1) should advance to the standalone-model field")

        model.moveFocus(1)
        expect(model.focusedRoleIndex == 1 && model.focusedField == .effort, "moveFocus(1) should advance to the standalone-effort field")

        model.moveFocus(1)
        expect(model.focusedRoleIndex == 2 && model.focusedField == .model, "moveFocus(1) should advance to the worker-model field")

        model.moveFocus(1)
        expect(model.focusedRoleIndex == 2 && model.focusedField == .effort, "moveFocus(1) should advance to the worker-effort field")

        model.moveFocus(1)
        expect(
            model.selectedAgentIndex == 0 && model.focusedRoleIndex == 0 && model.focusedField == .model,
            "moveFocus should wrap forward within the tab, never spilling into the next tab"
        )

        model.moveFocus(-1)
        expect(
            model.selectedAgentIndex == 0 && model.focusedRoleIndex == 2 && model.focusedField == .effort,
            "moveFocus should wrap backward within the tab"
        )
    }

    private static func moveTabSwitchesAgentAndResetsFocus() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        model.moveFocus(2)
        expect(model.focusedRoleIndex == 1 && model.focusedField == .model, "sanity: focus moved off the tab's first field")

        model.moveTab(1)
        expect(model.selectedAgentIndex == 1, "moveTab(1) should advance to the next agent")
        expect(
            model.focusedRoleIndex == 0 && model.focusedField == .model,
            "switching tabs should reset focus to the new tab's first field"
        )

        model.moveTab(1)
        expect(model.selectedAgentIndex == 0, "moveTab should wrap forward past the last agent")

        model.moveTab(-1)
        expect(model.selectedAgentIndex == 1, "moveTab should wrap backward past the first agent")

        model.selectTab(0)
        expect(model.selectedAgentIndex == 0, "selectTab should jump directly to the given agent")
    }

    private static func cyclingFocusedValueAffectsOnlyTheFocusedField() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        model.setModelOptions(
            [SessionModelOption(id: "gpt-5.6-terra", label: "gpt-5.6-terra"), SessionModelOption(id: "gpt-5.6-sol", label: "gpt-5.6-sol")],
            defaultModel: "",
            agent: "codex",
            role: "master"
        )
        model.setEffortOptions(["low", "high"], defaultLevel: "", agent: "codex", role: "master")

        model.moveTab(1)
        expect(
            model.selectedAgent == "codex" && model.focusedRoleIndex == 0 && model.focusedField == .model,
            "sanity: switching tabs should land on codex's master-model field"
        )
        let codexMasterIndex = model.index(agent: "codex", role: "master")!
        model.cycleFocusedValue(1)
        expect(model.rows[codexMasterIndex].selectedModel == "gpt-5.6-terra", "cycling while the model field is focused should change the model")
        expect(model.rows[codexMasterIndex].selectedReasoningEffort.isEmpty, "the effort field must not change while the model field is focused")

        model.moveFocus(1)
        expect(model.focusedField == .effort, "sanity: focus should now be on the effort field")
        model.cycleFocusedValue(1)
        expect(model.rows[codexMasterIndex].selectedReasoningEffort == "low", "cycling while the effort field is focused should change the effort")
        expect(model.rows[codexMasterIndex].selectedModel == "gpt-5.6-terra", "the model field must not change while the effort field is focused")

        let claudeMasterIndex = model.index(agent: "claude", role: "master")!
        expect(model.rows[claudeMasterIndex].selectedModelOption == nil, "an unrelated row must not be affected")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError("RoleDefaultsLogicTests failed: \(message)")
        }
    }
}
