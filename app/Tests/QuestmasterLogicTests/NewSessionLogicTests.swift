import Foundation
import QuestmasterCore

struct NewSessionLogicTests {
    static func run() {
        roleControlsTitleAndMasterFlag()
        focusMovesThroughFieldsWithControlJAndK()
        selectorsCycleOnlyOnSelectableFields()
        enterCreatesExceptInPromptWhereControlSCreates()
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

        model.focusedField = .quest
        model.handle(.right)
        expect(model.selectedQuestID == "DEMO-1", "quest selector should include active quest")
        model.handle(.right)
        expect(model.selectedQuestID == nil, "quest selector should wrap through none")
    }

    private static func enterCreatesExceptInPromptWhereControlSCreates() {
        var model = NewSessionFormModel(role: .standalone, initialPath: "/tmp/project")
        model.focusedField = .title
        expect(model.creationRequested(by: .enter), "enter outside prompt should create")
        expect(!model.creationRequested(by: .controlS), "control-s outside prompt should not create")

        model.focusedField = .prompt
        expect(!model.creationRequested(by: .enter), "enter in prompt should insert newline")
        expect(model.creationRequested(by: .controlS), "control-s in prompt should create")
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
