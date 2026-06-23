import Foundation
import QuestmasterCore

struct NewSessionLogicTests {
    static func run() {
        roleControlsTitleAndMasterFlag()
        focusMovesThroughFieldsWithControlJAndK()
        focusCycleIncludesRole()
        selectorsCycleOnlyOnSelectableFields()
        selectShortcutsCycleOnlyOnSelectableFields()
        roleSelectsWithArrowKeys()
        colorEditPreviewsCommitsAndCancels()
        enterCreatesOutsidePromptWherePromptViewHandlesReturn()
        promptReturnKeyCreatesUnlessShiftIsHeld()
        submitPayloadTrimsFieldsAndRequiresPath()
        print("NewSessionLogicTests: all tests passed")
    }

    private static func roleControlsTitleAndMasterFlag() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.headerTitle == "New session", "standalone title mismatch")
        expect(!model.role.isMaster, "standalone should not be master")

        model.setRole(.master)
        expect(model.headerTitle == "New master session", "master title mismatch")
        expect(model.role.isMaster, "master should encode --master")
    }

    private static func focusMovesThroughFieldsWithControlJAndK() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        expect(model.focusedField == .path, "initial focus should be path")

        model.handle(.controlJ)
        expect(model.focusedField == .title, "control-j should move to title")
        model.handle(.controlJ)
        expect(model.focusedField == .agent, "control-j should move to agent")
        model.handle(.controlK)
        expect(model.focusedField == .title, "control-k should move back to title")
    }

    private static func focusCycleIncludesRole() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.handle(.controlK)
        expect(model.focusedField == .role, "control-k from path should wrap to role")
        model.handle(.controlJ)
        expect(model.focusedField == .path, "control-j from role should wrap to path")
    }

    private static func selectorsCycleOnlyOnSelectableFields() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            agents: ["claude", "codex"],
            colors: ["blue", "violet"],
            quests: [NewSessionQuestOption(id: "DEMO-1", title: "Demo")]
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
        expect(model.selectedColor == "blue", "color should not cycle outside edit mode")

        model.focusedField = .quest
        model.handle(.right)
        expect(model.selectedQuestID == "DEMO-1", "quest selector should include active quest")
        model.handle(.right)
        expect(model.selectedQuestID == nil, "quest selector should wrap through none")
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

        model.focusedField = .prompt
        expect(!model.handleSelectShortcut("h"), "prompt field should not consume h")
        expect(model.selectedAgent == "claude", "prompt shortcut should not cycle agent")
    }

    private static func roleSelectsWithArrowKeys() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.focusedField = .role
        model.handle(.right)
        expect(model.role == .master, "right should select master role")
        expect(model.handleSelectShortcut("h"), "role should consume h select-left")
        expect(model.role == .standalone, "h should select standalone role")
    }

    private static func colorEditPreviewsCommitsAndCancels() {
        var model = NewSessionFormModel(
            role: .standalone,
            initialPath: "/tmp/project",
            colors: ["blue", "green", "violet"]
        )
        model.focusedField = .color
        expect(model.beginColorEdit(), "c should enter color edit on color field")
        expect(model.isEditingColor, "color edit mode should be active")
        model.handle(.right)
        expect(model.selectedColor == "green", "right should preview next color")
        expect(!model.creationRequested(by: .enter), "enter should not create while editing color")
        expect(model.confirmColorEdit(), "enter should confirm color edit")
        expect(!model.isEditingColor, "confirm should exit color edit mode")
        expect(model.selectedColor == "green", "confirmed color should persist")

        expect(model.beginColorEdit(), "color edit should re-enter")
        model.handle(.right)
        expect(model.selectedColor == "violet", "color edit should preview another candidate")
        expect(model.cancelColorEdit(), "esc should cancel color edit")
        expect(model.selectedColor == "green", "cancel should restore committed color")

        expect(model.beginColorEdit(), "color edit should enter before focus change")
        model.focusedField = .title
        expect(!model.isEditingColor, "leaving color field should cancel color edit")
        expect(model.selectedColor == "green", "focus cancel should preserve committed color")
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NewSessionLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
