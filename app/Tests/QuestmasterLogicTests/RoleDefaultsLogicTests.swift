import Foundation
import QuestmasterCore

struct RoleDefaultsLogicTests {
    static func run() {
        rowsCoverEveryAgentAndRoleInOrder()
        modelSelectStartsOnDefaultAndTakesResolvedOptions()
        effortSelectStartsOnDefaultAndTakesResolvedOptions()
        settingRowOptionsOnlyAffectsThatRow()
        focusNavigationVisitsEveryFieldInOrder()
        cyclingFocusedValueAffectsOnlyTheFocusedField()
        print("RoleDefaultsLogicTests: all tests passed")
    }

    private static func rowsCoverEveryAgentAndRoleInOrder() {
        let model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(model.rows.count == 4, "2 agents x 2 roles should produce 4 rows, got \(model.rows.count)")
        expect(
            model.rows.map { "\($0.agent):\($0.role)" } == ["claude:master", "codex:master", "claude:worker", "codex:worker"],
            "rows should be role-major, master-then-worker: \(model.rows)"
        )
        expect(model.index(agent: "codex", role: "master") == 1, "index should locate the matching row")
        expect(model.index(agent: "pi", role: "worker") == nil, "index should return nil for an agent not in the model")
    }

    private static func modelSelectStartsOnDefaultAndTakesResolvedOptions() {
        var row = RoleDefaultRow(agent: "claude", role: "worker")
        expect(row.selectedModelOption.isDefault, "a fresh row should start on the default entry")
        expect(row.selectedModel.isEmpty, "the default entry should send no override")

        row.setModelOptions(
            [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "claude-opus-9-unreleased", label: "claude-opus-9-unreleased", note: "recent"),
            ],
            defaultModel: "sonnet"
        )
        expect(row.modelOptions.count == 3, "resolved models should append to the default entry")
        expect(row.modelOptions.first?.note == "sonnet", "the default entry should carry the harness default")
        expect(row.selectedModelOption.isDefault, "resolving should not change the selection")

        row.cycleModel(1)
        expect(row.selectedModel == "opus", "cycling right should select the first resolved model")
        row.cycleModel(1)
        expect(row.selectedModel == "claude-opus-9-unreleased", "cycling right again should reach the next model")
        row.cycleModel(-1)
        row.cycleModel(-1)
        expect(row.selectedModel.isEmpty, "cycling back past the first entry should wrap to the default")
    }

    private static func effortSelectStartsOnDefaultAndTakesResolvedOptions() {
        var row = RoleDefaultRow(agent: "codex", role: "master")
        row.setEffortOptions(["minimal", "low", "medium", "high", "xhigh"], defaultLevel: "xhigh")
        // xhigh is both the applied default and a member of the supported
        // list, so it must not appear a second time as a concrete entry.
        expect(row.effortOptions.count == 5, "the level matching the default must not be repeated")
        expect(row.effortOptions.first?.label == "xhigh", "the default entry should show the concrete applied level")

        row.cycleEffort(1)
        expect(row.selectedReasoningEffort == "minimal", "cycling should select the first resolved level")
        row.cycleEffort(-1)
        expect(row.selectedReasoningEffort.isEmpty, "cycling back should return to the default entry")
    }

    private static func settingRowOptionsOnlyAffectsThatRow() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet", agent: "claude", role: "master")
        model.cycleFocusedValue(1)
        expect(model.rows[0].selectedModel == "opus", "cycling the focused field should select its resolved model")
        expect(model.rows[1].selectedModelOption.isDefault, "an unrelated row must not be affected")
        expect(model.rows[2].modelOptions.count == 1, "a different (agent, role) row must not receive another row's options")
    }

    private static func focusNavigationVisitsEveryFieldInOrder() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(model.focusedRowIndex == 0 && model.focusedField == .model, "focus should start on the first row's model field")

        model.moveFocus(1)
        expect(model.focusedRowIndex == 0 && model.focusedField == .effort, "moveFocus(1) should advance to the same row's effort field")

        model.moveFocus(1)
        expect(model.focusedRowIndex == 1 && model.focusedField == .model, "moveFocus(1) should advance to the next row's model field")

        model.moveFocus(-1)
        expect(model.focusedRowIndex == 0 && model.focusedField == .effort, "moveFocus(-1) should step back to the previous row's effort field")

        model.moveFocus(-1)
        model.moveFocus(-1)
        expect(
            model.focusedRowIndex == model.rows.count - 1 && model.focusedField == .effort,
            "moveFocus should wrap backward past the first field to the last row's effort field"
        )

        model.moveFocus(1)
        expect(model.focusedRowIndex == 0 && model.focusedField == .model, "moveFocus should wrap forward past the last field")
    }

    private static func cyclingFocusedValueAffectsOnlyTheFocusedField() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        model.setModelOptions([SessionModelOption(id: "gpt-5.6-terra", label: "gpt-5.6-terra")], defaultModel: "gpt-5.6-terra", agent: "codex", role: "master")
        model.setEffortOptions(["low", "high"], defaultLevel: "high", agent: "codex", role: "master")

        model.moveFocus(2)
        expect(model.focusedRowIndex == 1 && model.focusedField == .model, "sanity: focus should land on codex:master's model field")
        model.cycleFocusedValue(1)
        expect(model.rows[1].selectedModel == "gpt-5.6-terra", "cycling while the model field is focused should change the model")
        expect(model.rows[1].selectedReasoningEffort.isEmpty, "the effort field must not change while the model field is focused")

        model.moveFocus(1)
        expect(model.focusedField == .effort, "sanity: focus should now be on the effort field")
        model.cycleFocusedValue(1)
        expect(model.rows[1].selectedReasoningEffort == "low", "cycling while the effort field is focused should change the effort")
        expect(model.rows[1].selectedModel == "gpt-5.6-terra", "the model field must not change while the effort field is focused")
        expect(model.rows[0].selectedModelOption.isDefault, "an unrelated row must not be affected")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError("RoleDefaultsLogicTests failed: \(message)")
        }
    }
}
