import Foundation
import QuestmasterCore

struct RoleDefaultsLogicTests {
    static func run() {
        rowsCoverEveryAgentAndRoleInOrder()
        modelSelectStartsOnDefaultAndTakesResolvedOptions()
        effortSelectStartsOnDefaultAndTakesResolvedOptions()
        settingRowOptionsOnlyAffectsThatRow()
        focusNavigationCyclesTheFocusedRowOnly()
        print("RoleDefaultsLogicTests: all tests passed")
    }

    private static func rowsCoverEveryAgentAndRoleInOrder() {
        let model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(model.rows.count == 4, "2 agents x 2 roles should produce 4 rows, got \(model.rows.count)")
        expect(
            model.rows.map { "\($0.agent):\($0.role)" } == ["claude:worker", "claude:master", "codex:worker", "codex:master"],
            "rows should be agent-major, worker-then-master: \(model.rows)"
        )
        expect(model.index(agent: "codex", role: "master") == 3, "index should locate the matching row")
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
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet", agent: "claude", role: "worker")
        model.cycleFocusedModel(1)
        expect(model.rows[0].selectedModel == "opus", "cycling the focused row should select its resolved model")
        expect(model.rows[1].selectedModelOption.isDefault, "an unrelated row must not be affected")
        expect(model.rows[2].modelOptions.count == 1, "a different agent's row must not receive another agent's options")
    }

    private static func focusNavigationCyclesTheFocusedRowOnly() {
        var model = RoleDefaultsSettingsModel(agents: ["claude", "codex"])
        expect(model.focusedRowIndex == 0, "focus should start on the first row")

        model.moveFocus(1)
        expect(model.focusedRowIndex == 1, "moveFocus(1) should advance one row")
        model.moveFocus(-1)
        model.moveFocus(-1)
        expect(model.focusedRowIndex == model.rows.count - 1, "moveFocus should wrap backward past the first row")

        model.moveFocus(1)
        expect(model.focusedRowIndex == 0, "moveFocus should wrap forward past the last row")

        model.setModelOptions([SessionModelOption(id: "gpt-5.6-terra", label: "gpt-5.6-terra")], defaultModel: "gpt-5.6-terra", agent: "claude", role: "master")
        model.moveFocus(1)
        model.cycleFocusedModel(1)
        expect(model.rows[1].selectedModel == "gpt-5.6-terra", "cycling after moving focus should affect the newly focused row")
        expect(model.rows[0].selectedModelOption.isDefault, "the previously focused row must not be affected")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError("RoleDefaultsLogicTests failed: \(message)")
        }
    }
}
