import Foundation
import QuestmasterCore

struct MutationRequestTests {
    static func run() {
        startTrimsOptionalFields()
        startOmitsNoColor()
        startEncodesModelOverrideAndOmitsDefault()
        startEncodesReasoningEffortOverrideAndOmitsDefault()
        startShellEncodesPlainTerminalData()
        startShellRequiresCwdAndOmitsBlankTitle()
        questMutationsEncodeQuestData()
        artifactDeleteEncodesArtifactData()
        deleteAndSwitchEncodeSessionData()
        renameSessionEncodesTitle()
        setRoleDefaultEncodesAgentRoleModelAndEffort()
        mutationFailureFeedbackNamesActionAndError()
        print("MutationRequestTests: all tests passed")
    }

    private static func startTrimsOptionalFields() {
        do {
            let request = try ServeMutationRequests.start(
                role: .master,
                title: " orchestrator ",
                cwd: " /tmp/project ",
                agent: " claude ",
                color: " violet ",
                prompt: "  "
            )
            let object = request.jsonObject(id: "start") as NSDictionary
            expect(object["method"] as? String == "start", "method mismatch")
            let data = object["data"] as? NSDictionary
            expect(data?["master"] as? String == "true", "master role was not encoded")
            expect(data?["title"] as? String == "orchestrator", "title was not trimmed")
            expect(data?["cwd"] as? String == "/tmp/project", "cwd was not trimmed")
            expect(data?["primary"] as? String == "claude", "agent was not encoded as primary")
            expect(data?["color"] as? String == "violet", "color was not trimmed")
            expect(data?["prompt"] == nil, "blank prompt should be omitted")
        } catch {
            fail("start request threw \(error)")
        }
    }

    private static func startOmitsNoColor() {
        do {
            let request = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: " /tmp/project ",
                agent: " codex ",
                color: NewSessionFormModel.noColor,
                prompt: nil
            )
            let object = request.jsonObject(id: "start-none") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(data?["cwd"] as? String == "/tmp/project", "cwd was not trimmed")
            expect(data?["primary"] as? String == "codex", "agent was not encoded")
            expect(data?["color"] == nil, "no color should be omitted")
        } catch {
            fail("no-color start request threw \(error)")
        }
    }

    private static func startEncodesModelOverrideAndOmitsDefault() {
        do {
            // An unknown id is encoded as typed: the harness decides whether a
            // model exists, so a model released today works today.
            let override = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: "/tmp/project",
                agent: "claude",
                color: NewSessionFormModel.noColor,
                prompt: nil,
                model: " claude-opus-9-unreleased "
            )
            let overrideData = (override.jsonObject(id: "start-model") as NSDictionary)["data"] as? NSDictionary
            expect(
                overrideData?["model"] as? String == "claude-opus-9-unreleased",
                "model override was not encoded verbatim"
            )

            let defaulted = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: "/tmp/project",
                agent: "claude",
                color: NewSessionFormModel.noColor,
                prompt: nil
            )
            let defaultedData = (defaulted.jsonObject(id: "start-default") as NSDictionary)["data"] as? NSDictionary
            expect(defaultedData?["model"] == nil, "the default entry should omit the model key")
        } catch {
            fail("model start request threw \(error)")
        }
    }

    // Mirrors startEncodesModelOverrideAndOmitsDefault.
    private static func startEncodesReasoningEffortOverrideAndOmitsDefault() {
        do {
            let override = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: "/tmp/project",
                agent: "claude",
                color: NewSessionFormModel.noColor,
                prompt: nil,
                reasoningEffort: " max "
            )
            let overrideData = (override.jsonObject(id: "start-effort") as NSDictionary)["data"] as? NSDictionary
            expect(
                overrideData?["reasoning_effort"] as? String == "max",
                "reasoning effort override was not encoded verbatim"
            )

            let defaulted = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: "/tmp/project",
                agent: "claude",
                color: NewSessionFormModel.noColor,
                prompt: nil
            )
            let defaultedData = (defaulted.jsonObject(id: "start-effort-default") as NSDictionary)["data"] as? NSDictionary
            expect(defaultedData?["reasoning_effort"] == nil, "the default entry should omit the reasoning_effort key")
        } catch {
            fail("reasoning effort start request threw \(error)")
        }
    }

    private static func startShellEncodesPlainTerminalData() {
        do {
            let request = try ServeMutationRequests.startShell(cwd: " /tmp/project ", title: " Project ")
            let object = request.jsonObject(id: "shell") as NSDictionary
            expect(object["method"] as? String == "start", "shell start method mismatch")
            let data = object["data"] as? NSDictionary
            expect(data?["cwd"] as? String == "/tmp/project", "shell cwd was not trimmed")
            expect(data?["shell"] as? String == "true", "shell flag was not encoded")
            expect(data?["title"] as? String == "Project", "shell title was not trimmed")
            expect(data?["primary"] == nil, "shell start should not encode a primary agent")
        } catch {
            fail("shell start request threw \(error)")
        }
    }

    private static func startShellRequiresCwdAndOmitsBlankTitle() {
        do {
            _ = try ServeMutationRequests.startShell(cwd: " ", title: "ignored")
            fail("blank shell cwd should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "cwd", "shell cwd missing field was \(field)")
        } catch {
            fail("blank shell cwd threw wrong error \(error)")
        }

        do {
            let request = try ServeMutationRequests.startShell(cwd: "/tmp/project", title: " ")
            let data = request.jsonObject(id: "shell-no-title")["data"] as? NSDictionary
            expect(data?["title"] == nil, "blank shell title should be omitted")
        } catch {
            fail("shell start without title threw \(error)")
        }
    }

    private static func deleteAndSwitchEncodeSessionData() {
        do {
            let delete = try ServeMutationRequests.delete(sessionID: " qm-a ")
            let deleteData = delete.jsonObject(id: "delete")["data"] as? NSDictionary
            expect(delete.method == "delete", "delete method mismatch")
            expect(deleteData?["session_id"] as? String == "qm-a", "delete session id should be trimmed")

            let switchRequest = try ServeMutationRequests.switchSession(sessionID: " qm-b ")
            let switchData = switchRequest.jsonObject(id: "switch")["data"] as? NSDictionary
            expect(switchRequest.method == "switch", "switch method mismatch")
            expect(switchData?["session_id"] as? String == "qm-b", "switch session id should be trimmed")
        } catch {
            fail("session request threw \(error)")
        }
    }

    private static func artifactDeleteEncodesArtifactData() {
        do {
            let sessionArtifact = try ServeMutationRequests.artifactDelete(path: " /tmp/plan.html ", sessionID: " qm-a ")
            let sessionData = sessionArtifact.jsonObject(id: "artifact-delete")["data"] as? NSDictionary
            expect(sessionArtifact.method == "artifact.delete", "artifact delete method mismatch")
            expect(sessionData?["path"] as? String == "/tmp/plan.html", "artifact path should be trimmed")
            expect(sessionData?["session_id"] as? String == "qm-a", "artifact session id should be trimmed")

            let globalArtifact = try ServeMutationRequests.artifactDelete(path: "/tmp/global.html", sessionID: " ")
            let globalData = globalArtifact.jsonObject(id: "artifact-delete-global")["data"] as? NSDictionary
            expect(globalData?["session_id"] == nil, "global artifact delete should omit session id")
        } catch {
            fail("artifact delete request threw \(error)")
        }
    }

    private static func renameSessionEncodesTitle() {
        do {
            let request = try ServeMutationRequests.renameSession(sessionID: " qm-a ", title: " Release triage ")
            let data = request.jsonObject(id: "rename")["data"] as? NSDictionary
            expect(request.method == "rename", "rename method mismatch")
            expect(data?["session_id"] as? String == "qm-a", "rename session id should be trimmed")
            expect(data?["title"] as? String == "Release triage", "rename title should be trimmed")
        } catch {
            fail("rename request threw \(error)")
        }

        do {
            _ = try ServeMutationRequests.renameSession(sessionID: "qm-a", title: " ")
            fail("blank rename title should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "title", "blank rename title missing field was \(field)")
        } catch {
            fail("blank rename title threw wrong error \(error)")
        }
    }

    private static func setRoleDefaultEncodesAgentRoleModelAndEffort() {
        do {
            let request = try ServeMutationRequests.setRoleDefault(
                agent: " claude ",
                role: " worker ",
                model: "claude-opus-9-unreleased",
                reasoningEffort: "low"
            )
            let data = request.jsonObject(id: "role-default")["data"] as? NSDictionary
            expect(request.method == "role_default.set", "role_default.set method mismatch")
            expect(data?["agent"] as? String == "claude", "agent should be trimmed")
            expect(data?["role"] as? String == "worker", "role should be trimmed")
            expect(data?["model"] as? String == "claude-opus-9-unreleased", "model should pass through")
            expect(data?["reasoning_effort"] as? String == "low", "reasoning effort should pass through")

            // Empty model/effort clears the override rather than throwing —
            // only agent and role are required.
            let clear = try ServeMutationRequests.setRoleDefault(agent: "claude", role: "worker", model: "", reasoningEffort: "")
            let clearData = clear.jsonObject(id: "role-default-clear")["data"] as? NSDictionary
            expect(clearData?["model"] as? String == "", "clearing should send an empty model")
            expect(clearData?["reasoning_effort"] as? String == "", "clearing should send an empty reasoning effort")
        } catch {
            fail("role default request threw \(error)")
        }

        do {
            _ = try ServeMutationRequests.setRoleDefault(agent: " ", role: "worker", model: "", reasoningEffort: "")
            fail("blank agent should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "agent", "blank agent missing field was \(field)")
        } catch {
            fail("blank agent threw wrong error \(error)")
        }
    }

    private static func questMutationsEncodeQuestData() {
        do {
            let add = try ServeMutationRequests.questAdd(NewQuestSubmitPayload(
                content: " Add quest ",
                projectID: " repo ",
                projectPath: " /tmp/repo ",
                projectName: " Repo "
            ), sessionID: " qm-a ")
            let addData = add.jsonObject(id: "quest-add")["data"] as? NSDictionary
            expect(add.method == "quest.add", "quest add method mismatch")
            expect(addData?["content"] as? String == "Add quest", "quest content should be trimmed")
            expect(addData?["project_id"] as? String == "repo", "quest project id should be encoded")
            expect(addData?["session_id"] as? String == "qm-a", "quest session id should be encoded")

            let edit = try ServeMutationRequests.questEdit(questID: " qst-1 ", payload: NewQuestSubmitPayload(
                content: " Updated ",
                projectID: " repo-b ",
                projectPath: " /tmp/repo-b ",
                projectName: " Repo B "
            ))
            let editData = edit.jsonObject(id: "quest-edit")["data"] as? NSDictionary
            expect(edit.method == "quest.edit", "quest edit method mismatch")
            expect(editData?["quest_id"] as? String == "qst-1", "quest edit id should be trimmed")
            expect(editData?["content"] as? String == "Updated", "quest edit content should be trimmed")
            expect(editData?["project_changed"] as? String == "true", "quest edit should mark project changed")
            expect(editData?["project_id"] as? String == "repo-b", "quest edit project id should be encoded")

            let clear = try ServeMutationRequests.questEdit(questID: "qst-1", payload: NewQuestSubmitPayload(content: "Updated"))
            let clearData = clear.jsonObject(id: "quest-clear")["data"] as? NSDictionary
            expect(clearData?["project_changed"] as? String == "true", "quest clear should mark project changed")
            expect(clearData?["project_id"] as? String == "", "quest clear project id should be empty")

        } catch {
            fail("quest mutation request threw \(error)")
        }
    }

    private static func mutationFailureFeedbackNamesActionAndError() {
        expect(
            MutationFailureFeedback.message(label: " delete qm-a ", errorDescription: "session not found") == "Could not delete qm-a: session not found",
            "mutation feedback should name the failed user action and serve error"
        )
        expect(
            MutationFailureFeedback.message(label: "", errorDescription: "") == "Mutation failed.",
            "mutation feedback should have a bounded fallback"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("MutationRequestTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
