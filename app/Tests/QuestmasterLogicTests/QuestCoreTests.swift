import Foundation
import QuestmasterCore

struct QuestCoreTests {
    static func run() {
        displayGroupsProjectsAlphabeticallyThenNoProject()
        displayFallsBackToProjectColorWithoutLiveSession()
        displayFiltersByProjectID()
        displayFiltersByTextAndProjectTokens()
        displayOrdersByCreatedNotUpdated()
        displayScrollsSectionStartsWithTheirTitle()
        displayRecoversDeletedSelectionToPreviousQuest()
        questLogPageSplitsTitleAndKeepsBodyVerbatim()
        questLogPageFooterUsesProjectAndDay()
        questLogFooterWrapsBetweenParts()
        questLogPageIsPlainWithoutABody()
        questLogStoreSyncsThroughTheFilter()
        questLogWrapsGreedilyWithoutPushingWordsDown()
        questLogStoreSelectsMovesAndRecovers()
        questLogStoreTargetsMarkedQuestsInListOrder()
        questLogStoreReturnsEffectsAndClosingClearsMarks()
        questLogKeysMapToCommands()
        questLogStoreJumpsToTheEdgesAndAsksForAScroll()
        displayEdgeSelectionJumpsToFirstAndLastAcrossSections()
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

    private static func questLogPageSplitsTitleAndKeepsBodyVerbatim() {
        let quest = QuestItem(id: "q", content: "\n# Add more meta data  \n\nThe idea\n\n- one\n- two  \n\n")
        let page = QuestLogPage(quest: quest, project: "dotfiles")
        expect(page.title == "Add more meta data", "title = \(page.title)")
        expect(page.body == "The idea\n\n- one\n- two", "body = \(page.body.debugDescription)")
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "Only a title"), project: "").body.isEmpty, "single-line quest should have no body")
    }

    private static func questLogPageFooterUsesProjectAndDay() {
        let same = QuestItem(id: "q", content: "T", createdAt: "2026-09-08T09:00:00Z", updatedAt: "2026-09-08T10:00:00Z")
        expect(
            QuestLogPage(quest: same, project: "dotfiles").footerParts == ["dotfiles", "Created: 2026/09/08", "Updated: 2026/09/08"],
            "both dates should show, even when equal: \(QuestLogPage(quest: same, project: "dotfiles").footerParts)"
        )
        let neverUpdated = QuestItem(id: "q", content: "T", createdAt: "2026-01-02T00:00:00Z")
        expect(QuestLogPage(quest: neverUpdated, project: "dotfiles").footerParts == ["dotfiles", "Created: 2026/01/02"], "without an updated time only the created part should show")
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "T", updatedAt: "2026-03-04T00:00:00Z"), project: "p").footerParts == ["p", "Updated: 2026/03/04"], "a missing created time is left out")
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "T", createdAt: "soon"), project: "p").footerParts == ["p"], "an unreadable timestamp should leave its date out")
    }

    private static func questLogFooterWrapsBetweenParts() {
        let page = QuestLogPage(title: "T", body: "", project: "dotfiles", created: "2026/09/08", updated: "2026/09/08")
        expect(page.footerLines(columns: 65, separatorColumns: 4) == [page.footerParts], "the footer should fit on one line at the page's width")
        expect(
            page.footerLines(columns: 32, separatorColumns: 4) == [["dotfiles", "Created: 2026/09/08"], ["Updated: 2026/09/08"]],
            "parts should move to the next line whole, without a leading diamond: \(page.footerLines(columns: 32, separatorColumns: 4))"
        )
        let long = QuestLogPage(title: "T", body: "", project: "a very long project name indeed", created: "2026/09/08", updated: "")
        expect(
            long.footerLines(columns: 20, separatorColumns: 4) == [["a very long project"], ["name indeed"], ["Created: 2026/09/08"]],
            "a project longer than a line should wrap like the description, without truncation: \(long.footerLines(columns: 20, separatorColumns: 4))"
        )
    }

    private static func questLogPageIsPlainWithoutABody() {
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "Restore terminal settings on login"), project: "").layout == .plain, "a title-only quest should be plain")
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "Only a title\n\n   \n"), project: "").layout == .plain, "blank lines alone are not a body")
        expect(QuestLogPage(quest: QuestItem(id: "q", content: "Title\n\nThe idea"), project: "").layout == .titled, "a quest with a body gets the titled page")
    }

    private static func questLogStoreSyncsThroughTheFilter() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [], query: "one")
        expect(QuestDisplayState.flatQuests(in: store.sections).map(\.id) == ["a1", "b1"], "text should filter the list")
        store.sync(quests: logQuests, repos: [], projectIDs: ["b"])
        expect(store.selectedID == "b1", "a filtered-out selection should recover to a visible quest, got \(String(describing: store.selectedID))")
        store.sync(quests: logQuests, repos: [], query: "nothing matches")
        expect(store.sections.isEmpty && store.selectedID == nil, "no matches should leave nothing selected")
    }

    private static func questLogWrapsGreedilyWithoutPushingWordsDown() {
        let line = "The idea is to make questmaster also work well as a tmux session handler"
        expect(
            QuestLogPage.wrapped(line, columns: 65) == "The idea is to make questmaster also work well as a tmux session\nhandler",
            "a lone last word should wrap by itself, got \(QuestLogPage.wrapped(line, columns: 65).debugDescription)"
        )
        expect(QuestLogPage.wrapped("ab cd\n\nef", columns: 2) == "ab\ncd\n\nef", "typed breaks and blank lines are kept")
        expect(QuestLogPage.wrapped("abcdefgh", columns: 3) == "abc\ndef\ngh", "an over-long word should be split")
        expect(QuestLogPage.wrapped("fits", columns: 0) == "fits", "zero columns leaves the text alone")
    }

    private static let logQuests = [
        QuestItem(id: "a1", content: "A one", projectID: "a", projectName: "alpha", createdAt: "2026-07-03T02:00:00Z"),
        QuestItem(id: "a2", content: "A two", projectID: "a", projectName: "alpha", createdAt: "2026-07-03T01:00:00Z"),
        QuestItem(id: "b1", content: "B one", projectID: "b", projectName: "beta", createdAt: "2026-07-03T03:00:00Z"),
    ]

    private static func questLogStoreSelectsMovesAndRecovers() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.selectedID == "a1", "first sync should select the first quest, got \(String(describing: store.selectedID))")
        expect(store.selectedPage?.project == "alpha", "page project should be the section title")
        _ = store.handle(.moveDown)
        _ = store.handle(.moveDown)
        expect(store.selectedID == "b1", "j should move across sections")
        _ = store.handle(.moveDown)
        expect(store.selectedID == "a1", "j should wrap to the top")
        _ = store.handle(.moveUp)
        expect(store.selectedID == "b1", "k should wrap to the bottom")
        store.select("a2")
        store.select("missing")
        expect(store.selectedID == "a2", "clicking selects; an unknown id is ignored")
        store.sync(quests: [logQuests[0], logQuests[2]], repos: [])
        expect(store.selectedID == "a1", "a deleted selection should fall back to the quest above it")
        store.sync(quests: [], repos: [])
        expect(store.selectedID == nil && store.selectedPage == nil, "no quests should leave nothing selected")
    }

    private static func questLogStoreTargetsMarkedQuestsInListOrder() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.targets.map(\.id) == ["a1"], "with nothing marked the selection is the target")
        store.select("b1")
        _ = store.handle(.toggleMark)
        store.select("a1")
        _ = store.handle(.toggleMark)
        expect(store.targets.map(\.id) == ["a1", "b1"], "marked targets should follow list order, got \(store.targets.map(\.id))")
        _ = store.handle(.toggleMark)
        expect(store.markedIDs == ["b1"], "space again should unmark")
        store.sync(quests: Array(logQuests.prefix(2)), repos: [])
        expect(store.markedIDs.isEmpty, "marks on removed quests should be dropped")
    }

    private static func questLogStoreReturnsEffectsAndClosingClearsMarks() {
        let store = QuestLogStore()
        expect(store.handle(.start) == nil && store.handle(.edit) == nil, "an empty log has nothing to act on")
        store.sync(quests: logQuests, repos: [])
        store.open()
        expect(store.handle(.start) == .start([logQuests[0]]), "s should start the selected quest")
        expect(store.handle(.edit) == .edit(logQuests[0]), "e should edit the selected quest")
        expect(store.handle(.delete) == .delete([logQuests[0]]), "d should delete the selected quest")
        expect(store.handle(.copy) == .copy([logQuests[0]]), "y should copy the selected quest")
        expect(store.handle(.close) == .close, "esc should close")
        _ = store.handle(.toggleMark)
        store.close()
        expect(!store.isOpen && store.markedIDs.isEmpty, "closing should clear marks")
        let generation = store.openGeneration
        store.open()
        store.open()
        expect(store.openGeneration == generation + 1, "each opening counts once, so the opening animation plays once per open")
        store.close()
        expect(store.selectedID == "a1", "closing should keep the selection for the next open")
    }

    private static func questLogKeysMapToCommands() {
        expect(QuestLogCommand.from(characters: "j", keyCode: 38) == .moveDown, "j")
        expect(QuestLogCommand.from(characters: "k", keyCode: 40) == .moveUp, "k")
        expect(QuestLogCommand.from(characters: nil, keyCode: 125) == .moveDown, "down arrow")
        expect(QuestLogCommand.from(characters: nil, keyCode: 126) == .moveUp, "up arrow")
        expect(QuestLogCommand.from(characters: "s", keyCode: 1) == .start, "s")
        expect(QuestLogCommand.from(characters: "e", keyCode: 14) == .edit, "e")
        expect(QuestLogCommand.from(characters: "d", keyCode: 2) == .delete, "d")
        expect(QuestLogCommand.from(characters: "y", keyCode: 16) == .copy, "y")
        expect(QuestLogCommand.from(characters: " ", keyCode: 49) == .toggleMark, "space")
        expect(QuestLogCommand.from(characters: "\u{1b}", keyCode: 53) == .close, "esc")
        expect(QuestLogCommand.from(characters: "/", keyCode: 44) == .focusFilter, "/ should focus the filter")
        expect(QuestLogCommand.from(characters: nil, keyCode: 121) == .pageDown, "PageDown scrolls the page")
        expect(QuestLogCommand.from(characters: nil, keyCode: 116) == .pageUp, "PageUp scrolls the page")
        expect(QuestLogCommand.from(characters: "d", keyCode: 2, modifiers: [.control]) == .halfPageDown, "⌃d scrolls half a page down")
        expect(QuestLogCommand.from(characters: "u", keyCode: 32, modifiers: [.control]) == .halfPageUp, "⌃u scrolls half a page up")
        expect(QuestLogCommand.from(characters: "s", keyCode: 1, modifiers: [.control]) == nil, "⌃s must not start a session")
        let store = QuestLogStore()
        expect(store.handle(.pageDown) == nil, "with nothing selected there is no page to scroll")
        store.sync(quests: logQuests, repos: [])
        expect(store.handle(.pageDown) == .scrollPage(0.9) && store.handle(.halfPageUp) == .scrollPage(-0.5), "page keys scroll by 0.9 and half pages")
        expect(QuestLogCommand.from(characters: "S", keyCode: 1) == nil, "shifted letters are not quest log keys")
        expect(QuestLogCommand.from(characters: "x", keyCode: 7) == nil, "x is unbound")
        expect(QuestLogCommand.from(characters: "d", keyCode: 2, modifiers: [.option]) == nil, "⌥d must not open Abandon")
        expect(QuestLogCommand.from(characters: "s", keyCode: 1, modifiers: [.option]) == nil, "⌥s must not send forth")
        expect(QuestLogCommand.from(characters: "d", keyCode: 2, modifiers: [.control, .option]) == nil, "⌃⌥d is not ⌃d")
        expect(QuestLogCommand.from(characters: " ", keyCode: 49, modifiers: [.shift]) == nil, "Shift isn't part of the space binding")
        expect(QuestLogCommand.from(characters: nil, keyCode: 125, modifiers: [.option]) == nil, "⌥↓ is not a list key")
        expect(QuestLogCommand.from(characters: "\r", keyCode: 36) == .edit, "Return edits, as in the quest dock")
        expect(QuestLogCommand.from(characters: "g", keyCode: 5) == .jumpToFirstPrefix, "g starts gg")
        expect(QuestLogCommand.from(characters: "G", keyCode: 5, modifiers: [.shift]) == .jumpToLast, "Shift-G jumps to the last quest")
        expect(QuestLogCommand.from(characters: "G", keyCode: 5) == .jumpToLast, "Caps Lock G jumps to the last quest")
        expect(QuestLogCommand.from(characters: "G", keyCode: 5, modifiers: [.option, .shift]) == nil, "⌥G is not G")
    }

    private static func questLogStoreJumpsToTheEdgesAndAsksForAScroll() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        let ids = QuestDisplayState.flatQuests(in: store.sections).map(\.id)
        let nonce = store.scrollNonce
        _ = store.handle(.jumpToLast)
        expect(store.selectedID == ids.last && store.scrollNonce == nonce + 1, "G should select the last quest and ask for a scroll")
        _ = store.handle(.jumpToLast)
        expect(store.scrollNonce == nonce + 2, "G on the last quest should still scroll to it")
        _ = store.handle(.jumpToFirstPrefix)
        expect(store.selectedID == ids.last, "one g only arms gg")
        _ = store.handle(.jumpToFirstPrefix)
        expect(store.selectedID == ids.first && store.scrollNonce == nonce + 3, "gg should select the first quest and ask for a scroll")
        _ = store.handle(.jumpToFirstPrefix)
        _ = store.handle(.moveDown)
        _ = store.handle(.jumpToFirstPrefix)
        expect(store.selectedID == ids.dropFirst().first, "a command between the g's cancels gg")
    }

    private static func displayEdgeSelectionJumpsToFirstAndLastAcrossSections() {
        let quests = [
            QuestItem(id: "qst-b", content: "Beta", projectID: "repo-b", projectName: "Alpha Beta", updatedAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", projectName: "Zeta Repo", updatedAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-none", content: "No project", updatedAt: "2026-07-03T04:00:00Z"),
        ]
        let sections = QuestDisplayState.sections(quests: quests, repos: [TrackerRepo(id: "repo-a", name: "Zeta Repo", color: "green", sessions: [])])
        let ids = QuestDisplayState.flatQuests(in: sections).map(\.id)
        expect(QuestDisplayState.edgeSelection(atStart: true, in: sections) == ids.first, "gg should land on the first quest across sections")
        expect(QuestDisplayState.edgeSelection(atStart: false, in: sections) == "qst-none", "G should land on the last quest across sections")
        expect(QuestDisplayState.edgeSelection(atStart: true, in: []) == nil, "edge selection with no quests should be nil")
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

    private static func displayFiltersByTextAndProjectTokens() {
        let quests = [
            QuestItem(id: "qst-a", content: "Ship the filter", projectID: "repo-a"),
            QuestItem(id: "qst-b", content: "Ship the page", projectID: "repo-b"),
            QuestItem(id: "qst-c", content: "Tidy notes", projectID: "repo-b"),
        ]
        let byText = QuestDisplayState.sections(quests: quests, repos: [], query: "  ship ")
        expect(QuestDisplayState.flatQuests(in: byText).map(\.id).sorted() == ["qst-a", "qst-b"], "text should match case-insensitively, trimmed")
        let both = QuestDisplayState.sections(quests: quests, repos: [], query: "ship", projectIDs: ["repo-b"])
        expect(QuestDisplayState.flatQuests(in: both).map(\.id) == ["qst-b"], "text and project tokens should both apply")
    }

    private static func displayOrdersByCreatedNotUpdated() {
        let quests = [
            QuestItem(id: "qst-old-edited", content: "Old, just edited", projectID: "p", createdAt: "2026-07-01T00:00:00Z", updatedAt: "2026-07-09T00:00:00Z"),
            QuestItem(id: "qst-new", content: "New", projectID: "p", createdAt: "2026-07-05T00:00:00Z", updatedAt: "2026-07-05T00:00:00Z"),
            QuestItem(id: "qst-tie-b", content: "Tie b", projectID: "p", createdAt: "2026-07-03T00:00:00Z"),
            QuestItem(id: "qst-tie-a", content: "Tie a", projectID: "p", createdAt: "2026-07-03T00:00:00Z"),
        ]
        let order = QuestDisplayState.flatQuests(in: QuestDisplayState.sections(quests: quests, repos: [])).map(\.id)
        expect(order == ["qst-new", "qst-tie-a", "qst-tie-b", "qst-old-edited"], "quests should sort newest created first, ties by id, edits not moving them: \(order)")
    }

    private static func displayScrollsSectionStartsWithTheirTitle() {
        let sections = QuestDisplayState.sections(quests: logQuests, repos: [])
        expect(QuestDisplayState.scrollTarget(for: "a1", in: sections) == .top, "the first quest should scroll the list to the top")
        expect(QuestDisplayState.scrollTarget(for: "b1", in: sections) == .sectionStart(sectionID: "b"), "a section's first quest should bring its title along")
        expect(QuestDisplayState.scrollTarget(for: "a2", in: sections) == .row(id: "a2"), "other quests scroll to their row")
        expect(QuestDisplayState.scrollTarget(for: "missing", in: sections) == nil && QuestDisplayState.scrollTarget(for: nil, in: sections) == nil, "nothing to scroll to")
    }

    private static func displayRecoversDeletedSelectionToPreviousQuest() {
        let quests = [
            QuestItem(id: "qst-above", content: "Above", createdAt: "2026-07-03T03:00:00Z"),
            QuestItem(id: "qst-deleted", content: "Deleted", createdAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-below", content: "Below", createdAt: "2026-07-03T01:00:00Z"),
        ]
        let before = QuestDisplayState.sections(quests: quests, repos: [])
        let after = QuestDisplayState.sections(quests: [quests[0], quests[2]], repos: [])

        expect(
            QuestDisplayState.recoveredSelection(
                current: "qst-deleted",
                in: after,
                previouslyDisplayedQuests: QuestDisplayState.flatQuests(in: before)
            ) == "qst-above",
            "deleted quest should select the previous visible quest"
        )
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
