import Foundation
import QuestmasterCore

struct NewSessionLogicTests {
    static func run() {
        focusMovesThroughFieldsWithControlJAndK()
        focusCycleWrapsThroughFields()
        defaultAgentListIncludesOpenCode()
        modelFieldStartsEmptyAndTakesSettingsDefault()
        typedModelSurvivesLaterResolves()
        modelSuggestionsMatchWhatIsTyped()
        acceptingAModelSuggestionPutsTheDropdownAway()
        browsingReachesEveryModel()
        modelRefreshKeyIsTheModelFieldsOwn()
        modelSearchStartsOnAKeyAndEndsOnEscOrLeaving()
        agentChangeDropsAnotherHarnessModel()
        setModelOptionsDropsWhitespaceOnlyIDs()
        cyclingASingleAgentListDoesNotResetModelOptions()
        effortSelectStartsUnconfiguredAndTakesResolvedOptions()
        effortSegmentIsInertWithoutLevels()
        effortKeysCycleOnlyWhereAnECannotBeTyped()
        submittingNeedsOnlyAPath()
        suggestionListHighlightsWrapsAndDismisses()
        agentChangeDropsTheResolvedEffortList()
        selectorsCycleOnlyOnSelectableFields()
        selectShortcutsCycleOnlyOnSelectableFields()
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

    private static func focusMovesThroughFieldsWithControlJAndK() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        expect(model.focusedField == .path, "initial focus should be path")
        model.setEffortOptions(["low", "high"])

        model.handle(.controlJ)
        expect(model.focusedField == .title, "control-j should move to title")
        model.handle(.controlJ)
        expect(model.focusedField == .agent, "control-j should move to agent")
        model.handle(.controlJ)
        expect(model.focusedField == .model, "control-j should move to model")
        model.handle(.controlJ)
        expect(model.focusedField == .prompt, "control-j should move from the model to the prompt: the effort segment is no stop")
        model.handle(.controlK)
        expect(model.focusedField == .model, "control-k should move back to model")
        expect(NewSessionField.formOrder == [.path, .title, .agent, .model, .prompt], "the visible inputs, top to bottom")
    }

    private static func focusCycleWrapsThroughFields() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        model.handle(.controlK)
        expect(model.focusedField == .prompt, "control-k from path should wrap to prompt")
        model.handle(.controlK)
        expect(model.focusedField == .model, "control-k from prompt should move to model")
        expect(!NewSessionField.formOrder.contains(.color), "New Session's fields should not include a colour")
    }

    private static func defaultAgentListIncludesOpenCode() {
        expect(
            NewSessionFormModel.defaultAgents == ["claude", "codex", "opencode", "pi"],
            "default agent order mismatch: \(NewSessionFormModel.defaultAgents)"
        )
    }

    // Options are never declared in the app — they come entirely from the
    // backend, so a newly released model needs no app change. The field is
    // free text: model ids are never validated.
    private static func modelFieldStartsEmptyAndTakesSettingsDefault() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        expect(model.modelOptions.isEmpty, "the field should start with no suggestions at all")
        expect(model.selectedModel.isEmpty, "an untouched field should send no model override")
        expect(model.submitPayload()?.model == "", "an untouched field should not override the model")

        model.setModelOptions(
            [SessionModelOption(id: "opus", label: "opus"), SessionModelOption(id: "claude-opus-9-unreleased", label: "claude-opus-9-unreleased")],
            defaultModel: "sonnet"
        )
        expect(model.selectedModel == "sonnet", "the field should start on Settings' default, even one the list doesn't offer")
        model.typeModel("my-own-model")
        expect(model.submitPayload()?.model == "my-own-model", "any typed id should reach the payload as typed")
        model.typeModel("  ")
        expect(model.submitPayload()?.model == "", "a blank field should send no override")
    }

    private static func typedModelSurvivesLaterResolves() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        model.setModelOptions([SessionModelOption(id: "sonnet", label: "sonnet")], defaultModel: "sonnet")
        model.typeModel("opus")
        model.setModelOptions([SessionModelOption(id: "haiku", label: "haiku")], defaultModel: "haiku")
        expect(model.selectedModel == "opus", "a resolve must not overwrite what the user typed")
        model.resetModelOptions()
        expect(model.selectedModel == "opus", "a failed resolve must not clear what the user typed")
    }

    private static func modelSuggestionsMatchWhatIsTyped() {
        var model = NewSessionFormModel(initialPath: "/tmp/project", initialFocus: .model)
        let ids = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "opus", "sonnet", "haiku"]
        model.setModelOptions(ids.map { SessionModelOption(id: $0, label: $0) }, defaultModel: "opus")
        model.startModelSearch(.editCurrent)
        expect(model.modelSuggestions.map(\.id) == Array(ids.dropFirst(1)), "editing the current id should browse, from the current model: \(model.modelSuggestions.map(\.id))")
        expect(model.highlightedModelSuggestion?.id == "opus", "browsing should highlight the current model")
        model.typeModel("haiku")
        expect(model.modelSuggestions.map(\.id) == ["haiku", "claude-haiku-5-5"], "the exact id should come first")
        model.typeModel("opus")
        expect(model.modelSuggestions.count == NewSessionFormModel.maxModelSuggestions, "retyping the starting text should browse again")
        model.typeModel("OP")
        expect(model.modelSuggestions.map(\.id) == ["opus", "claude-opus-5-5"], "a prefix match should come before a contains match, ignoring case")
        expect(model.highlightedModelSuggestion?.id == "opus", "the best match should be highlighted")
        model.typeModel("sonnet")
        expect(model.modelSuggestions.first?.id == "sonnet" && model.highlightedModelSuggestion?.id == "sonnet", "sonnet should come first and be highlighted")
        model.typeModel("gpt")
        expect(model.modelSuggestions.isEmpty && !model.showsModelSuggestions, "no match should list nothing")
        model.typeModel("")
        expect(model.modelSuggestions.count == NewSessionFormModel.maxModelSuggestions, "an empty field should browse the list")
        model.moveModelHighlight(-1)
        expect(model.highlightedModelSuggestion?.id == ids.last, "up from the first model should wrap to the last, past the visible rows")
        expect(model.modelSuggestions.last?.id == ids.last && model.visibleModelHighlightIndex == NewSessionFormModel.maxModelSuggestions - 1, "the visible rows should follow the highlight")
    }

    private static func browsingReachesEveryModel() {
        var model = NewSessionFormModel(initialPath: "/tmp/project", initialFocus: .model)
        let ids = (1...8).map { "model-\($0)" }
        model.setModelOptions(ids.map { SessionModelOption(id: $0, label: $0) }, defaultModel: "model-1")
        model.startModelSearch(.editCurrent)
        expect(model.modelMatches.count == 8 && model.modelSuggestions.count == NewSessionFormModel.maxModelSuggestions, "browsing should list every model, five at a time")
        for _ in 0..<6 {
            model.moveModelHighlight(1)
        }
        expect(model.highlightedModelSuggestion?.id == "model-7", "↓ should reach models past the first five")
        expect(model.modelSuggestions.map(\.id) == ["model-3", "model-4", "model-5", "model-6", "model-7"], "the rows should scroll with the highlight")
        expect(model.acceptHighlightedModel() && model.selectedModel == "model-7", "a model past the first five should be pickable")
    }

    private static func modelRefreshKeyIsTheModelFieldsOwn() {
        func refreshes(control: Bool = true, option: Bool = false, _ field: NewSessionField) -> Bool {
            NewSessionModelRefreshKey.refreshes(keyCode: 15, command: false, control: control, option: option, field: field)
        }
        expect(refreshes(.model), "⌃r should refresh the models in the model field")
        expect(!refreshes(control: false, .model) && !refreshes(option: true, .model), "plain r and ⌥⌃r are not the refresh key")
        for field in [NewSessionField.path, .title, .agent, .prompt] {
            expect(!refreshes(field), "⌃r refreshes nothing with \(field) focused")
        }
        expect(Keymap.NewSession.refreshModels.keyCodes == [15] && Keymap.NewSession.refreshModels.modifiers == [.control], "⌃r is the r key with control")
    }

    private static func acceptingAModelSuggestionPutsTheDropdownAway() {
        var model = NewSessionFormModel(initialPath: "/tmp/project", initialFocus: .model)
        model.setModelOptions([SessionModelOption(id: "claude-opus-5-5", label: "claude-opus-5-5")])
        expect(model.modelMode == .select && !model.showsModelSuggestions, "the field should start in SELECT, with no list")
        model.startModelSearch(.seed("o"))
        model.typeModel("opus")
        expect(model.modelMode == .search && model.showsModelSuggestions, "a match should show while searching")
        expect(model.acceptHighlightedModel(), "the highlighted suggestion should be taken")
        expect(model.selectedModel == "claude-opus-5-5", "the field should hold the taken id")
        expect(model.modelMode == .select && !model.showsModelSuggestions, "taking a suggestion should return to SELECT")
        expect(!model.acceptHighlightedModel(), "nothing should be taken in SELECT")
        model.startModelSearch(.editCurrent)
        model.typeModel("claude-opus-5-")
        expect(model.showsModelSuggestions, "typing again should bring the dropdown back")
        model.dismissModelSuggestions()
        expect(!model.showsModelSuggestions, "the dropdown can be put away")
    }

    private static func modelSearchStartsOnAKeyAndEndsOnEscOrLeaving() {
        var model = NewSessionFormModel(initialPath: "/tmp/project", initialFocus: .model)
        model.setModelOptions([], defaultModel: "sonnet")
        model.startModelSearch(.seed("x"))
        expect(model.modelMode == .search && model.selectedModel == "x", "a printable key should start a search on that text")
        model.endModelSearch(keepingText: false)
        expect(model.modelMode == .select && model.selectedModel == "sonnet", "Esc should restore the text the search started from")
        model.setModelOptions([], defaultModel: "opus")
        expect(model.selectedModel == "opus", "an untyped default should still follow resolves after Esc")
        model.startModelSearch(.editCurrent)
        expect(model.selectedModel == "opus", "Backspace or Return should edit the current text")
        model.typeModel("my-model")
        model.focusedField = .prompt
        expect(model.modelMode == .select && model.selectedModel == "my-model", "leaving the field should end the search and keep what was typed")
    }

    private static func agentChangeDropsAnotherHarnessModel() {
        var model = NewSessionFormModel(
            initialPath: "/tmp/project",
            agents: ["claude", "codex"]
        )
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        model.typeModel("opus")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "codex", "precondition: agent cycled")
        expect(model.selectedModel.isEmpty, "a claude model must not launch on codex, typed or not")
        expect(model.modelOptions.isEmpty, "the stale list should be dropped with the agent")

        model.setModelOptions([SessionModelOption(id: "gpt-5.6-sol", label: "gpt-5.6-sol")], defaultModel: "gpt-5.6-terra")
        expect(model.selectedModel == "gpt-5.6-terra", "the new agent's default should fill the field")

    }

    // A whitespace-only id would otherwise render as "selected" in the picker
    // while MutationRequests.start's trimming silently sends no override at
    // submit time — setModelOptions must drop it rather than offer a
    // selection that lies about what actually launches.
    private static func setModelOptionsDropsWhitespaceOnlyIDs() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        model.setModelOptions(
            [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "   ", label: "blank"),
            ],
            defaultModel: "sonnet"
        )
        expect(model.modelOptions.count == 1, "a whitespace-only id should be dropped, not offered")
        expect(!model.modelOptions.contains(where: { $0.label == "blank" }), "the blank entry must not appear in the picker")
    }

    // cycleSelection's .agent case must mirror setRole's "only reset on an
    // actual change" guard: with a single agent, cycling can't change the
    // selection, so an already-resolved model list must survive it.
    private static func cyclingASingleAgentListDoesNotResetModelOptions() {
        var model = NewSessionFormModel(
            initialPath: "/tmp/project",
            agents: ["claude"]
        )
        model.setModelOptions([SessionModelOption(id: "opus", label: "opus")], defaultModel: "sonnet")
        model.typeModel("opus")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "claude", "precondition: cycling a single-agent list is a no-op")
        expect(model.selectedModel == "opus", "a no-op agent cycle must not drop the typed model")
        expect(model.modelOptions.count == 1, "a no-op agent cycle must not drop the resolved model list")
    }

    // Mirrors modelSelectStartsUnconfiguredAndTakesResolvedOptions. Effort has
    // no row of its own — cycleReasoningEffort() is bound to `e` while the
    // Model field is focused — so it is exercised directly rather than
    // through focus + left/right.
    private static func effortSelectStartsUnconfiguredAndTakesResolvedOptions() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        expect(model.effortOptions.isEmpty, "the picker should start with no options at all")
        expect(model.selectedEffortOption == nil, "nothing should be selected before anything resolves")
        expect(model.selectedReasoningEffort.isEmpty, "an unconfigured picker should send no effort override")
        expect(model.submitPayload()?.reasoningEffort == "", "an untouched picker should not override the effort")

        model.setEffortOptions(["low", "medium", "high", "xhigh", "max"], defaultLevel: "xhigh")
        expect(model.effortOptions.count == 5, "every supported level should be a plain, unfiltered option")
        // "xhigh" is a resolved level here, so it seeds the selection.
        expect(model.selectedReasoningEffort == "xhigh", "resolving onto a default present in the list should select it")

        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort == "max", "cycling from xhigh should reach the next resolved level")
        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort.isEmpty, "cycling past the last level should wrap to nothing selected")
        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort == "low", "cycling from nothing selected should reach the first resolved level")
        expect(model.submitPayload()?.reasoningEffort == "low", "a picked level should reach the payload")
    }

    // Valid effort levels
    // are per harness (and per model, for Codex/OpenCode), so a stale
    // resolved list must not survive an agent or role change.
    private static func agentChangeDropsTheResolvedEffortList() {
        var model = NewSessionFormModel(
            initialPath: "/tmp/project",
            agents: ["claude", "codex"]
        )
        model.setEffortOptions(["low", "high"], defaultLevel: "xhigh")
        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort == "low", "precondition: low selected")

        model.focusedField = .agent
        model.handle(.right)
        expect(model.selectedAgent == "codex", "precondition: agent cycled")
        expect(model.selectedReasoningEffort.isEmpty, "a claude effort level must not launch on codex")
        expect(model.effortOptions.isEmpty, "the stale list should be dropped with the agent")

        model.setEffortOptions(["low", "ultra"], defaultLevel: "xhigh")
        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort == "low", "precondition: codex effort selected")

    }

    private static func effortSegmentIsInertWithoutLevels() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        model.setEffortOptions([], defaultLevel: "xhigh")
        expect(!model.hasEffortLevels, "a model without levels has none")
        expect(model.effortLabel == NewSessionFormModel.defaultEffortLabel, "the segment should read default")
        model.cycleReasoningEffort()
        expect(model.selectedReasoningEffort.isEmpty, "there is nothing to cycle")

        model.resetEffortOptions()
        model.setEffortOptions(["low", "high"], defaultLevel: "high")
        expect(model.effortLabel == "high", "the segment shows the level id")
        model.cycleReasoningEffort(-1)
        expect(model.selectedReasoningEffort == "low", "cycling back should reach the previous level")
        model.cycleReasoningEffort(-1)
        expect(model.effortLabel == NewSessionFormModel.defaultEffortLabel, "cycling should reach default, the harness's own level")
    }

    private static func effortKeysCycleOnlyWhereAnECannotBeTyped() {
        func cycles(_ characters: String, control: Bool = false, option: Bool = false, _ field: NewSessionField, _ mode: PickerFieldMode = .select) -> Bool {
            NewSessionEffortKey.cycles(characters: characters, keyCode: 14, command: false, control: control, option: option, field: field, mode: mode)
        }
        expect(cycles("e", .model, .select), "e should cycle in the model field's SELECT state")
        expect(!cycles("e", .model, .search), "e should type while searching")
        expect(cycles("e", control: true, .model, .select) && cycles("e", control: true, .model, .search), "⌃e should cycle in both states")
        expect(!cycles("´", option: true, .model, .search), "⌥e is the accent dead key, not an effort key")
        for field in [NewSessionField.path, .title, .agent, .color, .prompt] {
            expect(!cycles("e", field) && !cycles("e", control: true, field), "no effort key with \(field) focused")
        }
        expect(!NewSessionEffortKey.cycles(characters: "E", keyCode: 14, command: false, control: false, option: false, field: .model, mode: .select), "E (shift) is not the effort key")
        expect(Keymap.NewSession.cycleReasoningEffortInModel.keyCodes == [14] && Keymap.NewSession.cycleReasoningEffortInModel.modifiers == [.control], "⌃e is the e key with control")
    }

    private static func submittingNeedsOnlyAPath() {
        var model = NewSessionFormModel(initialPath: "")
        expect(!model.canSubmit, "Summon should wait for a path")
        model.path = "  "
        expect(!model.canSubmit, "a blank path is no path")
        model.path = "/tmp/project"
        expect(model.canSubmit, "a path is all Summon needs")
        model.setSubmitting(true)
        expect(!model.canSubmit, "Summon should be off while submitting")
    }

    private static func suggestionListHighlightsWrapsAndDismisses() {
        var list = SuggestionList()
        expect(!list.isVisible && list.highlighted == nil, "an empty list shows nothing")
        list.show(["/a", "/b"])
        expect(list.isVisible && list.highlighted == "/a", "a fresh list highlights its first row")
        list.moveHighlight(-1)
        expect(list.highlighted == "/b", "up from the first row should wrap")
        list.dismiss()
        expect(!list.isVisible, "a dismissed list hides")
        list.show(["/c"])
        expect(list.isVisible && list.highlighted == "/c", "new rows show again")
    }

    private static func selectorsCycleOnlyOnSelectableFields() {
        var model = NewSessionFormModel(
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

    }

    private static func selectShortcutsCycleOnlyOnSelectableFields() {
        var model = NewSessionFormModel(
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

    private static func defaultColorSelectIncludesNone() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
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
        var model = NewSessionFormModel(initialPath: "/tmp/project")
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
        var model = NewSessionFormModel(initialPath: " /tmp/project ")
        model.title = "  "
        model.prompt = "  hello\n "
        let payload = model.submitPayload()
        expect(payload != nil, "valid model should create a payload")
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
