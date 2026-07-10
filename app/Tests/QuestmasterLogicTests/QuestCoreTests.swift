import Foundation
import QuestmasterCore

struct QuestCoreTests {
    static func run() {
        displayGroupsProjectsAlphabeticallyThenNoProject()
        displayFallsBackToProjectColorWithoutLiveSession()
        displayFiltersByProjectID()
        newQuestFormBuildsPayload()
        startFromQuestsBuildsPromptAndRejectsMixedProjects()
        print("QuestCoreTests: all tests passed")
    }

    private static func displayGroupsProjectsAlphabeticallyThenNoProject() {
        // repo-a has a live tracker session but sorts after inactive repo-b's
        // title, proving sections interleave by title rather than splitting
        // into an active-first block.
        let quests = [
            QuestItem(id: "qst-b", content: "Beta", projectID: "repo-b", projectName: "Alpha Beta", updatedAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", projectName: "Zeta Repo", updatedAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-none", content: "No project", updatedAt: "2026-07-03T04:00:00Z"),
        ]
        let repos = [
            TrackerRepo(id: "repo-a", name: "Zeta Repo", color: "green", sessions: []),
        ]
        let sections = QuestDisplayState.sections(quests: quests, repos: repos)
        expect(sections.map(\.id) == ["repo-b", "repo-a", "no-project"], "section order = \(sections.map(\.id))")
        expect(sections[0].quests.map(\.id) == ["qst-b"], "repo-b active quests mismatch")
        expect(QuestDisplayState.recoveredSelection(current: nil, in: sections) == "qst-b", "selection should recover first visible quest")
        expect(QuestDisplayState.movedSelection(current: "qst-b", delta: 1, in: sections) == "qst-a", "selection should move across sections")
    }

    private static func displayFallsBackToProjectColorWithoutLiveSession() {
        let quests = [
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", projectName: "Alpha Repo", updatedAt: "2026-07-03T02:00:00Z"),
        ]
        let projects = [
            TrackerProject(id: "repo-a", name: "Alpha Repo", color: "green"),
        ]
        let sections = QuestDisplayState.sections(quests: quests, repos: [], projects: projects)
        expect(sections.map(\.color) == ["green"], "section color should fall back to the persisted project color = \(sections.map(\.color))")
    }

    private static func displayFiltersByProjectID() {
        let quests = [
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", updatedAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-b", content: "Beta", projectID: "repo-b", updatedAt: "2026-07-03T01:00:00Z"),
        ]
        let sections = QuestDisplayState.sections(
            quests: quests,
            repos: [TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [])],
            projectID: "repo-b"
        )
        expect(sections.map(\.id) == ["repo-b"], "project filter sections = \(sections.map(\.id))")
        expect(sections.first?.quests.map(\.id) == ["qst-b"], "project filter quests mismatch")
    }

    private static func newQuestFormBuildsPayload() {
        var model = NewQuestFormModel(
            content: "  Ship quests  ",
            projects: [NewQuestProjectOption(projectID: "repo", projectPath: "/tmp/repo", projectName: "repo")]
        )
        guard let payload = model.submitPayload() else {
            fail("new quest payload was nil")
        }
        expect(payload.content == "Ship quests", "content was not trimmed")
        expect(payload.projectID == "repo", "project id mismatch")
    }

    private static func startFromQuestsBuildsPromptAndRejectsMixedProjects() {
        let quests = [
            QuestItem(id: "qst-one", content: "First\nline", projectID: "repo", projectPath: "/tmp/repo"),
            QuestItem(id: "qst-two", content: "Second", projectID: "repo", projectPath: "/tmp/repo"),
        ]
        do {
            let request = try ServeMutationRequests.startFromQuests(quests, title: "quests", agent: "codex")
            let data = request.jsonObject(id: "start")["data"] as? NSDictionary
            expect(data?["cwd"] as? String == "/tmp/repo", "cwd mismatch")
            expect(data?["prompt"] as? String == "- First\n  line\n- Second", "prompt mismatch: \(String(describing: data?["prompt"]))")
        } catch {
            fail("startFromQuests threw \(error)")
        }

        do {
            _ = try ServeMutationRequests.startFromQuests([
                quests[0],
                QuestItem(id: "qst-other", content: "Other", projectID: "other", projectPath: "/tmp/other"),
            ], title: nil, agent: "codex")
            fail("mixed project quests should throw")
        } catch ServeMutationRequestError.invalid {
        } catch {
            fail("mixed project threw wrong error \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("QuestCoreTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
