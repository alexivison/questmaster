import Foundation
import QuestmasterCore

struct NewSessionLogicTests {
    static func run() {
        roleControlsMasterFlag()
        focusMovesThroughFieldsWithControlJAndK()
        focusCycleIncludesRole()
        defaultAgentListIncludesOpenCode()
        modelSelectStartsOnDefaultAndTakesResolvedOptions()
        modelSelectionSurvivesARefreshThatStillOffersIt()
        agentAndRoleChangesDropAnotherHarnessModel()
        setModelOptionsDropsWhitespaceOnlyIDs()
        cyclingASingleAgentListDoesNotResetModelOptions()
        effortSelectStartsOnDefaultAndTakesResolvedOptions()
        roleAndAgentChangesDropTheResolvedEffortList()
        selectorsCycleOnlyOnSelectableFields()
        selectShortcutsCycleOnlyOnSelectableFields()
        roleSelectsWithArrowKeys()
        defaultColorSelectIncludesNone()
        initialColorUsesTheSameColorCycle()
        colorSelectCyclesDirectly()
        enterCreatesOutsidePromptWherePromptViewHandlesReturn()
        promptReturnKeyCreatesUnlessShiftIsHeld()
        submitPayloadTrimsFieldsAndRequiresPath()
        resolvedColorForSaveKeepsRealColorSelections()
        resolvedColorForSavePreservesUntouchedInitialColor()
        resolvedColorForSaveReturnsNoneWhenActivelyClearedThisSession()
        print("NewSessionLogicTests: all tests passed")
    }

    private static func roleControlsMasterFlag() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(!model.role.isMaster, "standalone should not be master")

        model.setRole(.master)
        expect(model.role.isMaster, "master should encode --master")
    }

    private static func focusMovesThroughFieldsWithControlJAndK() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.focusedField == .path, "initial focus should be path")

        model.handle(.controlJ)
        expect(model.focusedField == .title, "control-j should move to title")
        model.handle(.controlJ)
        expect(model.focusedField == .agent, "control-j should move to agent")
        model.handle(.controlJ)
        expect(model.focusedField == .model, "control-j should move to model")
        model.handle(.controlJ)
        expect(model.focusedField == .reasoningEffort, "control-j should move to reasoning effort")
        model.handle(.controlJ)
        expect(model.focusedField == .role, "control-j should move to role")
        model.handle(.controlJ)
        expect(model.focusedField == .color, "control-j should move to color")
        model.handle(.controlK)
        expect(model.focusedField == .role, "control-k should move back to role")
    }

    private static func focusCycleIncludesRole() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.handle(.controlK)
        expect(model.focusedField == .prompt, "control-k from path should wrap to prompt")
        model.handle(.controlK)
        expect(model.focusedField == .color, "control-k from prompt should move to color")
    }

    private static func defaultAgentListIncludesOpenCode() {
        expect(
            NewSessionFormModel.defaultAgents == ["claude", "codex", "opencode", "pi"],
            "default agent order mismatch: \(NewSessionFormModel.defaultAgents)"
        )
    }

    // The app owns exactly one model entry — "default" — and receives the rest
    // from the backend, so a newly released model needs no app change.
    private static func modelSelectStartsOnDefaultAndTakesResolvedOptions() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.modelOptions.count == 1, "the picker should start with only the default entry")
        expect(model.selectedModelOption.isDefault, "the default entry should be selected")
        expect(model.selectedModel.isEmpty, "the default entry should send no model override")
        expect(model.submitPayload()?.model == "", "an untouched picker should not override the model")

        model.setModelOptions(
            [
                SessionModelOption(id: "opus", label: "opus", note: "alias · tracks Claude Opus 5"),
                SessionModelOption(id: "claude-opus-9-unreleased", label: "claude-opus-9-unreleased", note: "recent"),
            ],
            defaultModel: "sonnet"
        )
        expect(model.modelOptions.count == 3, "resolved models should append to the default entry")
        expect(model.modelOptions.first?.note == "sonnet", "the default entry should carry the role default")
        expect(model.selectedModelOption.isDefault, "resolving should not change the selection")

        model.focusedField = .model
        model.handle(.right)
        expect(model.selectedModel == "opus", "right should select the first resolved model")
        expect(model.submitPayload()?.model == "opus", "a picked model should reach the payload")
        model.handle(.right)
        expect(model.selectedModel == "claude-opus-9-unreleased", "right should reach a model no catalog knows")
        model.handle(.left)
        expect(model.selectedModel == "opus", "left should cycle back")
        model.handle(.left)
        expect(model.selectedModel.isEmpty, "left should return to the default entry")
    }

    private static func modelSelectionSurvivesARefreshThatStillOffersIt() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        model.focusedField = .model
        model.handle(.right)
        expect(model.selectedModel == "opus", "precondition: opus selected")

        model.setModelOptions(
            [
                SessionModelOption(id: "sonnet", label: "sonnet"),
                SessionModelOption(id: "opus", label: "opus"),
            ],
            defaultModel: "sonnet"
        )
        expect(model.selectedModel == "opus", "a refresh that still offers the model should keep it selected")

        model.setModelOptions([SessionModelOption(id: "haiku", label: "haiku")], defaultModel: "sonnet")
        expect(model.selectedModel.isEmpty, "a refresh without the model should fall back to the default")
    }

    private static func agentAndRoleChangesDropAnotherHarnessModel() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude", "codex"]
        )
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        model.focusedField = .model
        model.handle(.right)
        expect(model.selectedModel == "opus", "precondition: opus selected")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "codex", "precondition: agent cycled")
        expect(model.selectedModel.isEmpty, "a claude model must not launch on codex")
        expect(model.modelOptions.count == 1, "the stale list should be dropped with the agent")

        model.setModelOptions([SessionModelOption(id: "gpt-5.6-sol", label: "gpt-5.6-sol")], defaultModel: "gpt-5.6-terra")
        model.focusedField = .model
        model.handle(.right)
        expect(model.selectedModel == "gpt-5.6-sol", "precondition: codex model selected")

        model.setRole(.master)
        expect(model.selectedModel.isEmpty, "the role decides the default model, so its list is re-resolved")
    }

    // A whitespace-only id would otherwise render as "selected" in the picker
    // while MutationRequests.start's trimming silently sends no override at
    // submit time — setModelOptions must drop it rather than offer a
    // selection that lies about what actually launches.
    private static func setModelOptionsDropsWhitespaceOnlyIDs() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.setModelOptions(
            [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "   ", label: "blank"),
            ],
            defaultModel: "sonnet"
        )
        expect(model.modelOptions.count == 2, "a whitespace-only id should be dropped, not offered")
        expect(!model.modelOptions.contains(where: { $0.label == "blank" }), "the blank entry must not appear in the picker")
    }

    // cycleSelection's .agent case must mirror setRole's "only reset on an
    // actual change" guard: with a single agent, cycling can't change the
    // selection, so an already-resolved model list must survive it.
    private static func cyclingASingleAgentListDoesNotResetModelOptions() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude"]
        )
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        model.focusedField = .model
        model.handle(.right)
        expect(model.selectedModel == "opus", "precondition: opus selected")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "claude", "precondition: cycling a single-agent list is a no-op")
        expect(model.selectedModel == "opus", "a no-op agent cycle must not drop the resolved model list")
    }

    // Mirrors modelSelectStartsOnDefaultAndTakesResolvedOptions: the app owns
    // exactly one effort entry — "default" — and receives the rest from the
    // backend.
    private static func effortSelectStartsOnDefaultAndTakesResolvedOptions() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.effortOptions.count == 1, "the picker should start with only the default entry")
        expect(model.selectedEffortOption.isDefault, "the default entry should be selected")
        expect(model.selectedReasoningEffort.isEmpty, "the default entry should send no effort override")
        expect(model.submitPayload()?.reasoningEffort == "", "an untouched picker should not override the effort")

        model.setEffortOptions(["low", "medium", "high", "xhigh", "max"], defaultLevel: "xhigh")
        expect(model.effortOptions.count == 6, "resolved levels should append to the default entry")
        expect(model.effortOptions.first?.label == "xhigh", "the default entry should show the concrete applied level")
        expect(model.selectedEffortOption.isDefault, "resolving should not change the selection")

        model.focusedField = .reasoningEffort
        model.handle(.right)
        expect(model.selectedReasoningEffort == "low", "right should select the first resolved level")
        expect(model.submitPayload()?.reasoningEffort == "low", "a picked level should reach the payload")
        model.handle(.left)
        expect(model.selectedReasoningEffort.isEmpty, "left should return to the default entry")
    }

    // Mirrors agentAndRoleChangesDropAnotherHarnessModel: valid effort levels
    // are per harness (and per model, for Codex/OpenCode), so a stale
    // resolved list must not survive an agent or role change.
    private static func roleAndAgentChangesDropTheResolvedEffortList() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude", "codex"]
        )
        model.setEffortOptions(["low", "high", "xhigh"], defaultLevel: "xhigh")
        model.focusedField = .reasoningEffort
        model.handle(.right)
        expect(model.selectedReasoningEffort == "low", "precondition: low selected")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "codex", "precondition: agent cycled")
        expect(model.selectedReasoningEffort.isEmpty, "a claude effort level must not launch on codex")
        expect(model.effortOptions.count == 1, "the stale list should be dropped with the agent")

        model.setEffortOptions(["minimal", "xhigh", "ultra"], defaultLevel: "xhigh")
        model.focusedField = .reasoningEffort
        model.handle(.right)
        expect(model.selectedReasoningEffort == "minimal", "precondition: codex effort selected")

        model.setRole(.master)
        expect(model.selectedReasoningEffort.isEmpty, "the role decides the default effort, so its list is re-resolved")
    }

    private static func selectorsCycleOnlyOnSelectableFields() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude", "codex"],
            colors: ["blue", "violet"]
        )
        model.focusedField = .path
        model.handle(.right)
        expect(model.selectedAgent == "claude", "path right arrow should not cycle agent")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "codex", "agent right arrow should cycle forward")
        model.handle(.left)
        expect(model.selectedAgent == "claude", "agent left arrow should cycle backward")

        model.focusedField = .color
        model.handle(.right)
        expect(model.selectedColor == "violet", "color right arrow should cycle forward")
        model.handle(.left)
        expect(model.selectedColor == "blue", "color left arrow should cycle backward")

        model.focusedField = .role
        model.handle(.right)
        expect(model.role == .master, "role right arrow should select master")
    }

    private static func selectShortcutsCycleOnlyOnSelectableFields() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude", "codex"],
            colors: ["blue", "violet"]
        )

        model.focusedField = .title
        expect(!model.handleSelectShortcut("l"), "title field should not consume l")
        expect(model.selectedAgent == "claude", "text field shortcut should not cycle agent")

        model.focusedField = .agent
        expect(model.handleSelectShortcut("l"), "agent field should consume l")
        expect(model.selectedAgent == "codex", "l should cycle select field right")
        expect(model.handleSelectShortcut("h"), "agent field should consume h")
        expect(model.selectedAgent == "claude", "h should cycle select field left")

        model.focusedField = .color
        expect(model.handleSelectShortcut("l"), "color field should consume l directly")
        expect(model.selectedColor == "violet", "l should cycle color right")
        expect(model.handleSelectShortcut("h"), "color field should consume h directly")
        expect(model.selectedColor == "blue", "h should cycle color left")

        model.focusedField = .prompt
        expect(!model.handleSelectShortcut("h"), "prompt field should not consume h")
        expect(model.selectedAgent == "claude", "prompt shortcut should not cycle agent")
    }

    private static func roleSelectsWithArrowKeys() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.focusedField = .role
        model.handle(.right)
        expect(model.role == .master, "right should select master role")
        model.handle(.right)
        expect(model.role == .standalone, "right from master should wrap to standalone")
        expect(model.handleSelectShortcut("h"), "role should consume h select-left")
        expect(model.role == .master, "h from standalone should wrap to master")
        model.handle(.left)
        expect(model.role == .standalone, "left from master should wrap to standalone")
    }

    private static func defaultColorSelectIncludesNone() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.selectedColor == NewSessionFormModel.noColor, "default color should be no color")
        expect(model.selectedColorLabel == "none", "no-color label should render as none")

        let payload = model.submitPayload()
        expect(payload?.color == NewSessionFormModel.noColor, "no-color payload should use empty color")

        model.focusedField = .color
        model.handle(.right)
        expect(model.selectedColor == "blue", "right from no color should select blue")
        model.handle(.left)
        expect(model.selectedColor == NewSessionFormModel.noColor, "left from blue should return to no color")
    }

    private static func initialColorUsesTheSameColorCycle() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            initialColor: "green"
        )
        model.focusedField = .color

        expect(model.selectedColor == "green", "initial color should be selected")
        model.handle(.right)
        expect(model.selectedColor == "yellow", "right should continue from the initial color")
        expect(model.handleSelectShortcut("h"), "h should use the same color cycle")
        expect(model.selectedColor == "green", "h should return to the initial color")
    }

    private static func colorSelectCyclesDirectly() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            colors: ["blue", "green", "violet"]
        )
        model.focusedField = .color
        model.handle(.right)
        expect(model.selectedColor == "green", "right should select next color")
        model.handle(.right)
        expect(model.selectedColor == "violet", "right should select the next color again")
        model.handle(.left)
        expect(model.selectedColor == "green", "left should select previous color")
        expect(model.creationRequested(by: .enter), "enter should create after direct color selection")
        model.focusedField = .title
        expect(model.selectedColor == "green", "focus change should preserve selected color")
    }

    private static func enterCreatesOutsidePromptWherePromptViewHandlesReturn() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.focusedField = .title
        expect(model.creationRequested(by: .enter), "enter outside prompt should create")
        expect(!model.creationRequested(by: .controlS), "control-s outside prompt should not create")

        model.focusedField = .prompt
        expect(!model.creationRequested(by: .enter), "prompt return should be handled by the prompt text view")
        expect(model.creationRequested(by: .controlS), "control-s in prompt should create")
    }

    private static func promptReturnKeyCreatesUnlessShiftIsHeld() {
        expect(NewSessionPromptReturnAction.forReturn(shiftHeld: false) == .create, "return should create from prompt")
        expect(NewSessionPromptReturnAction.forReturn(shiftHeld: true) == .newline, "shift-return should insert prompt newline")
    }

    private static func submitPayloadTrimsFieldsAndRequiresPath() {
        var model = NewSessionFormModel(role: .master, initialPath: " /tmp/project ")
        model.title = "  "
        model.prompt = "  hello\n "
        let payload = model.submitPayload()
        expect(payload != nil, "valid model should create a payload")
        expect(payload?.role == .master, "payload role mismatch")
        expect(payload?.path == "/tmp/project", "path should be trimmed")
        expect(payload?.title == nil, "blank title should stay auto-generated")
        expect(payload?.prompt == "hello", "prompt should be trimmed")

        model.path = "  "
        expect(model.submitPayload() == nil, "blank path should not create a payload")
        expect(model.errorMessage == "path is required", "blank path error mismatch")
    }

    private static func resolvedColorForSaveKeepsRealColorSelections() {
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "violet",
                selectedColorIndex: 5,
                initialColorIndex: 0,
                initialColor: "none"
            ) == "violet",
            "a real color selection should pass through regardless of index history"
        )
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "violet",
                selectedColorIndex: 0,
                initialColorIndex: 0,
                initialColor: ""
            ) == "violet",
            "a real color selection should pass through even at the untouched index"
        )
    }

    private static func resolvedColorForSavePreservesUntouchedInitialColor() {
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "",
                selectedColorIndex: 0,
                initialColorIndex: 0,
                initialColor: ""
            ) == "",
            "untouched no-color selection should preserve an original empty color"
        )
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "",
                selectedColorIndex: 0,
                initialColorIndex: 0,
                initialColor: "none"
            ) == "none",
            "untouched no-color selection should preserve an original literal none"
        )
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "",
                selectedColorIndex: 3,
                initialColorIndex: 3,
                initialColor: "cyan"
            ) == "cyan",
            "untouched selection should preserve the original raw color even if it was a real color name"
        )
    }

    private static func resolvedColorForSaveReturnsNoneWhenActivelyClearedThisSession() {
        expect(
            NewSessionFormModel.resolvedColorForSave(
                selectedColor: "",
                selectedColorIndex: 0,
                initialColorIndex: 5,
                initialColor: "cyan"
            ) == "none",
            "navigating to the no-color entry from a different starting index should become literal none"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NewSessionLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
