import Foundation
import QuestmasterCore

struct QuestCoreTests {
    static func run() {
        flatListIsNewestCreatedFirstAcrossProjects()
        displayOrdersByCreatedNotUpdated()
        projectTabsFollowTheUsersOrderAndOnlyListProjectsWithQuests()
        noProjectQuestsAppearOnlyUnderAll()
        tabFallsBackToAllWhenItsProjectLosesItsLastQuest()
        tabsStepWithBracketsAndWrap()
        tagFiltersMatchAnySelectedTagWithinAGroupAndAllGroups()
        selectionRecoversAcrossTabAndFilterChanges()
        questTagChipsNameSizeFirstThenTypesInOrder()
        displayRecoversDeletedSelectionToPreviousQuest()
        questLogPageSplitsTitleAndKeepsBodyVerbatim()
        questLogPageFooterUsesProjectAndDay()
        questLogFooterWrapsBetweenParts()
        questLogPageIsPlainWithoutABody()
        questLogStoreSyncsThroughTheFilter()
        questLogWrapsGreedilyWithoutPushingWordsDown()
        questLogStoreSelectsMovesAndRecovers()
        questLogStoreTargetsMarkedQuestsInListOrder()
        questLogCopyTextUsesIDsForSelectedAndMarkedTargets()
        questLogStoreReturnsEffectsAndClosingClearsMarks()
        questLogStoreScrollsByPagesAndOnlyTakesItsOwnCommands()
        questLogStoreJumpsToTheEdgesAndAsksForAScroll()
        questLogStoreMovesRowsWithJAndKOnly()
        displayEdgeSelectionJumpsToFirstAndLastQuest()
        newQuestFormBuildsPayload()
        newQuestFormNeedsAProjectAndContent()
        newQuestContentKeepsTabAsText()
        projectSearchRanksByNameThenPath()
        projectSearchSwitchesToDirectoriesForAPath()
        projectOptionsDeduplicateAndAbbreviate()
        editQuestKeepsItsProjectUnlessItChanges()
        noProjectIsAnExplicitChoice()
        anAssignedQuestCanBeUnfiled()
        browsingReachesEveryProject()
        leavingTheProjectFieldEndsItsSearch()
        startFromQuestsBuildsIDPromptAndRejectsMixedProjects()
        print("QuestCoreTests: all tests passed")
    }

    private static func flatListIsNewestCreatedFirstAcrossProjects() {
        // Projects don't group the list: a newer quest in another project sits above an older one.
        let quests = [
            QuestItem(id: "qst-b", content: "Beta", projectID: "repo-b", projectName: "Beta", createdAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", projectName: "Alpha", createdAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-none", content: "No project", createdAt: "2026-07-03T04:00:00Z"),
        ]
        let visible = QuestDisplayState.visibleQuests(quests: quests, filter: QuestListFilter(), projectID: nil)
        expect(visible.map(\.id) == ["qst-none", "qst-a", "qst-b"], "one list, newest created first: \(visible.map(\.id))")
        expect(QuestDisplayState.recoveredSelection(current: nil, in: visible) == "qst-none", "selection should recover to the newest quest")
        expect(QuestDisplayState.movedSelection(current: "qst-none", delta: 1, in: visible) == "qst-a", "selection should move across projects")
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
        store.sync(quests: logQuests, repos: [], filter: QuestListFilter(text: "one"))
        expect(store.visibleQuests.map(\.id) == ["b1", "a1"], "text should filter the list")
        store.selectTab(2)
        expect(store.visibleQuests.map(\.id) == ["b1"], "the tab should narrow the text filter's list")
        store.sync(quests: logQuests, repos: [], filter: QuestListFilter(text: "nothing matches"))
        expect(store.visibleQuests.isEmpty && store.selectedID == nil, "no matches should leave nothing selected")
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

    private static func projectTabsFollowTheUsersOrderAndOnlyListProjectsWithQuests() {
        let quests = [
            QuestItem(id: "qst-a", content: "A", projectID: "repo-a", projectName: "Alpha", createdAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-x", content: "X", projectID: "repo-x", projectName: "Xray", createdAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-b", content: "B", projectID: "repo-b", projectName: "Beta", createdAt: "2026-07-03T03:00:00Z"),
            QuestItem(id: "qst-none", content: "None", createdAt: "2026-07-03T04:00:00Z"),
        ]
        let listed = [
            TrackerProject(id: "repo-b", name: "Beta", color: "green"),
            TrackerProject(id: "repo-a", name: "Alpha", color: "green"),
        ]
        let tabs = QuestDisplayState.projectTabs(quests: quests, repos: [], projects: listed)
        expect(tabs.map(\.projectID) == ["repo-b", "repo-a", "repo-x"], "tabs should follow the project order, unlisted last: \(tabs.map(\.projectID))")
        expect(tabs.map(\.title) == ["Beta", "Alpha", "Xray"], "tab titles should follow the same order: \(tabs.map(\.title))")
        expect(QuestDisplayState.projectTabs(quests: [quests[3]], repos: [], projects: listed).isEmpty, "a quest without a project should give no tab")
    }

    private static func noProjectQuestsAppearOnlyUnderAll() {
        let quests = [
            QuestItem(id: "qst-a", content: "A", projectID: "a", projectName: "alpha", createdAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-none", content: "None", createdAt: "2026-07-03T02:00:00Z"),
        ]
        let store = QuestLogStore()
        store.sync(quests: quests, repos: [])
        expect(store.tabTitles == ["All", "alpha"], "only projects with quests get a tab: \(store.tabTitles)")
        expect(store.visibleQuests.map(\.id) == ["qst-none", "qst-a"], "All should show the quest without a project")
        store.selectTab(1)
        expect(store.visibleQuests.map(\.id) == ["qst-a"], "a project tab should hide the quest without a project")
        store.selectTab(0)
        store.select("qst-none")
        expect(store.selectedPage?.project == "No project", "a quest without a project should say so in its footer")
    }

    private static func tabFallsBackToAllWhenItsProjectLosesItsLastQuest() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        store.selectTab(2)
        expect(store.selectedProjectID == "b" && store.selectedTabIndex == 2, "the beta tab should be selected")
        store.sync(quests: Array(logQuests.prefix(2)), repos: [])
        expect(store.selectedProjectID == nil && store.selectedTabIndex == 0, "a tab whose project has no quests left should fall back to All")
        expect(store.visibleQuests.map(\.id) == ["a1", "a2"], "All should show what is left: \(store.visibleQuests.map(\.id))")
        store.selectTab(1)
        store.sync(quests: logQuests, repos: [])
        expect(store.selectedProjectID == "a", "a tab should stay selected while its project has quests")
    }

    private static func tabsStepWithBracketsAndWrap() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.handle(.nextTab) == nil && store.selectedTabIndex == 1, "] should step to the first project tab")
        _ = store.handle(.nextTab)
        expect(store.selectedTabIndex == 2, "] should step to the next tab")
        _ = store.handle(.nextTab)
        expect(store.selectedTabIndex == 0, "] past the last tab should wrap to All")
        _ = store.handle(.previousTab)
        expect(store.selectedTabIndex == 2, "[ from All should wrap to the last tab")
        store.selectTab(7)
        expect(store.selectedTabIndex == 2, "a tab index outside the tabs should do nothing")
    }

    private static func tagFiltersMatchAnySelectedTagWithinAGroupAndAllGroups() {
        let quests = [
            QuestItem(id: "bug-small", content: "Fix the save button", types: ["bug"], size: "S", projectID: "p", createdAt: "2026-07-03T05:00:00Z"),
            QuestItem(id: "decision-small", content: "Pick a tab order", types: ["decision"], size: "S", createdAt: "2026-07-03T04:00:00Z"),
            QuestItem(id: "feature-research-large", content: "Sync the save state", types: ["feature", "research"], size: "L", createdAt: "2026-07-03T03:00:00Z"),
            QuestItem(id: "untagged", content: "Save somewhere", createdAt: "2026-07-03T02:00:00Z"),
        ]
        func ids(_ filter: QuestListFilter, projectID: String? = nil) -> [String] {
            QuestDisplayState.visibleQuests(quests: quests, filter: filter, projectID: projectID).map(\.id)
        }
        expect(ids(QuestListFilter(types: ["bug"])) == ["bug-small"], "one type should match the quests that carry it")
        expect(ids(QuestListFilter(types: ["bug", "research"])) == ["bug-small", "feature-research-large"], "types in one group should match any of them")
        expect(ids(QuestListFilter(sizes: ["S", "L"])) == ["bug-small", "decision-small", "feature-research-large"], "sizes in one group should match any of them, untagged quests excluded")
        expect(ids(QuestListFilter(types: ["bug", "decision"], sizes: ["S"])) == ["bug-small", "decision-small"], "a type group and a size group should both have to match")
        expect(ids(QuestListFilter(types: ["research"], sizes: ["S"])).isEmpty, "no quest is both research and small")
        expect(ids(QuestListFilter(text: "save", types: ["bug", "feature"])) == ["bug-small", "feature-research-large"], "text should narrow the tag matches")
        expect(ids(QuestListFilter(text: "pick", sizes: ["S"])) == ["decision-small"], "text, then size, should keep one quest")
        expect(ids(QuestListFilter(types: ["bug"]), projectID: "q").isEmpty, "the tab should narrow the tag matches too")
        expect(ids(QuestListFilter(types: ["bug"]), projectID: "p") == ["bug-small"], "the tab's own quests should still match")
    }

    private static func selectionRecoversAcrossTabAndFilterChanges() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.selectedID == "b1", "the newest quest should be selected first, got \(String(describing: store.selectedID))")
        store.select("a2")
        store.selectTab(2)
        expect(store.selectedID == "b1", "a tab that drops the selection should recover to the quest above it, got \(String(describing: store.selectedID))")
        store.selectTab(1)
        expect(store.selectedID == "a1", "a tab with no quest above the selection should recover to the first quest, got \(String(describing: store.selectedID))")
        store.sync(quests: logQuests, repos: [], filter: QuestListFilter(text: "two"))
        expect(store.selectedID == "a2", "a filter that drops the selection should recover into what is left, got \(String(describing: store.selectedID))")
        store.sync(quests: logQuests, repos: [], filter: QuestListFilter(text: "nothing matches"))
        expect(store.selectedID == nil && store.visibleQuests.isEmpty, "no matches should leave nothing selected")
    }

    private static func questTagChipsNameSizeFirstThenTypesInOrder() {
        let quest = QuestItem(id: "q", content: "T", types: ["cleanup", "bug", "other"], size: "M")
        expect(QuestDisplayState.tagChipNames(for: quest) == ["M", "Bug", "Cleanup"], "size first, then the types in the fixed order, unknown tags left out: \(QuestDisplayState.tagChipNames(for: quest))")
        expect(QuestDisplayState.tagChipNames(for: QuestItem(id: "q", content: "T")).isEmpty, "an untagged quest should have no chips")
        expect(QuestTagType.improvement.displayName == "Improvement" && QuestSize.large.rawValue == "L", "tag IDs should map to their names")
    }

    private static let logQuests = [
        QuestItem(id: "a1", content: "A one", projectID: "a", projectName: "alpha", createdAt: "2026-07-03T02:00:00Z"),
        QuestItem(id: "a2", content: "A two", projectID: "a", projectName: "alpha", createdAt: "2026-07-03T01:00:00Z"),
        QuestItem(id: "b1", content: "B one", projectID: "b", projectName: "beta", createdAt: "2026-07-03T03:00:00Z"),
    ]

    private static func questLogStoreSelectsMovesAndRecovers() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.selectedID == "b1", "first sync should select the newest quest, got \(String(describing: store.selectedID))")
        expect(store.selectedPage?.project == "beta", "page project should be the quest's project name")
        _ = store.handle(.move(1))
        expect(store.selectedID == "a1", "j should move to the next quest")
        _ = store.handle(.move(1))
        _ = store.handle(.move(1))
        expect(store.selectedID == "b1", "j should wrap to the top")
        _ = store.handle(.move(-1))
        expect(store.selectedID == "a2", "k should wrap to the bottom")
        store.select("a1")
        store.select("missing")
        expect(store.selectedID == "a1", "clicking selects; an unknown id is ignored")
        store.select("a2")
        store.sync(quests: [logQuests[0], logQuests[2]], repos: [])
        expect(store.selectedID == "a1", "a deleted selection should fall back to the quest above it")
        store.sync(quests: [], repos: [])
        expect(store.selectedID == nil && store.selectedPage == nil, "no quests should leave nothing selected")
    }

    private static func questLogStoreTargetsMarkedQuestsInListOrder() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        expect(store.targets.map(\.id) == ["b1"], "with nothing marked the selection is the target")
        _ = store.handle(.toggleMark)
        store.select("a2")
        _ = store.handle(.toggleMark)
        expect(store.targets.map(\.id) == ["b1", "a2"], "marked targets should follow list order, got \(store.targets.map(\.id))")
        _ = store.handle(.toggleMark)
        expect(store.markedIDs == ["b1"], "space again should unmark")
        store.sync(quests: Array(logQuests.prefix(2)), repos: [])
        expect(store.markedIDs.isEmpty, "marks on removed quests should be dropped")
    }

    private static func questLogCopyTextUsesIDsForSelectedAndMarkedTargets() {
        let quests = [
            QuestItem(id: "qst-a", content: "Private quest body A"),
            QuestItem(id: "qst-b id", content: "Private quest body B"),
        ]
        let store = QuestLogStore()
        store.sync(quests: quests, repos: [])
        expect(QuestLogCopyText.text(for: store.targets) == "qst-a", "copy should use the selected quest ID")
        store.select("qst-b id")
        _ = store.handle(.toggleMark)
        store.select("qst-a")
        _ = store.handle(.toggleMark)
        expect(QuestLogCopyText.text(for: store.targets) == "qst-a 'qst-b id'", "copy should quote marked IDs in list order")
    }

    private static func questLogStoreReturnsEffectsAndClosingClearsMarks() {
        let store = QuestLogStore()
        expect(store.handle(.start) == nil && store.handle(.edit) == nil, "an empty log has nothing to act on")
        store.sync(quests: logQuests, repos: [])
        store.open()
        let newest = logQuests[2]
        expect(store.handle(.start) == .start([newest]), "s should start the selected quest")
        expect(store.handle(.edit) == .edit(newest), "e should edit the selected quest")
        expect(store.handle(.delete) == .delete([newest]), "d should delete the selected quest")
        expect(store.handle(.copy) == .copy([newest]), "y should copy the selected quest")
        expect(store.handle(.close) == .close, "esc should close")
        _ = store.handle(.toggleMark)
        store.close()
        expect(!store.isOpen && store.markedIDs.isEmpty, "closing should clear marks")
        let generation = store.openGeneration
        store.open()
        store.open()
        expect(store.openGeneration == generation + 1, "each opening counts once, so the opening animation plays once per open")
        store.close()
        expect(store.selectedID == "b1", "closing should keep the selection for the next open")
    }

    private static func questLogStoreScrollsByPagesAndOnlyTakesItsOwnCommands() {
        let store = QuestLogStore()
        expect(store.handle(.page(1)) == nil, "with nothing selected there is no page to scroll")
        store.sync(quests: logQuests, repos: [])
        expect(store.handle(.page(1)) == .scrollPage(0.9) && store.handle(.halfPage(-1)) == .scrollPage(-0.5), "page keys scroll by 0.9 and half pages")
        expect(store.handle(.open) == nil && store.handle(.jumpToTopPrefix) == nil, "Return and a lone g do nothing in the Quest Log")
        expect(store.handle(.refresh) == nil && store.handle(.editRepo) == nil && store.handle(.toggleWorkersCollapsed) == nil, "the tracker's and Watcher's keys do nothing in the Quest Log")
    }

    /// The rows move with the modal keys: j and k, while the arrows, Tab and ⌃J/⌃K take nothing. A lone g still
    /// arms gg, so the list keys see every press.
    private static func questLogStoreMovesRowsWithJAndKOnly() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        func command(_ characters: String?, _ keyCode: UInt16, _ modifiers: Set<Keymap.Modifier> = []) -> ListCommand? {
            store.command(for: Keymap.KeyPress(keyCode: keyCode, character: characters, modifiers: modifiers))
        }
        expect(command("j", 38) == .move(1), "j should move the Quest Log down")
        expect(command("k", 40) == .move(-1), "k should move the Quest Log up")
        expect(command(nil, 125) == nil && command(nil, 126) == nil, "the arrows should take nothing in the Quest Log")
        expect(command(nil, 48) == nil, "Tab should take nothing in the Quest Log")
        expect(command("j", 38, [.control]) == nil && command("k", 40, [.control]) == nil, "⌃j and ⌃k should take nothing in the Quest Log")
        expect(command("g", 5) == .jumpToTopPrefix, "one g should still arm gg in the Quest Log")
    }

    private static func questLogStoreJumpsToTheEdgesAndAsksForAScroll() {
        let store = QuestLogStore()
        store.sync(quests: logQuests, repos: [])
        let ids = store.visibleQuests.map(\.id)
        let nonce = store.scrollNonce
        _ = store.handle(.jumpToBottom)
        expect(store.selectedID == ids.last && store.scrollNonce == nonce + 1, "G should select the last quest and ask for a scroll")
        _ = store.handle(.jumpToBottom)
        expect(store.scrollNonce == nonce + 2, "G on the last quest should still scroll to it")
        _ = store.handle(.jumpToTop)
        expect(store.selectedID == ids.first && store.scrollNonce == nonce + 3, "gg should select the first quest and ask for a scroll")
    }

    private static func displayEdgeSelectionJumpsToFirstAndLastQuest() {
        let quests = [
            QuestItem(id: "qst-b", content: "Beta", projectID: "repo-b", projectName: "Beta", createdAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-a", content: "Alpha", projectID: "repo-a", projectName: "Alpha", createdAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-none", content: "No project", createdAt: "2026-07-03T04:00:00Z"),
        ]
        let visible = QuestDisplayState.visibleQuests(quests: quests, filter: QuestListFilter(), projectID: nil)
        expect(QuestDisplayState.edgeSelection(atStart: true, in: visible) == "qst-none", "gg should land on the newest quest")
        expect(QuestDisplayState.edgeSelection(atStart: false, in: visible) == "qst-b", "G should land on the oldest quest")
        expect(QuestDisplayState.edgeSelection(atStart: true, in: []) == nil, "edge selection with no quests should be nil")
    }

    private static func displayOrdersByCreatedNotUpdated() {
        let quests = [
            QuestItem(id: "qst-old-edited", content: "Old, just edited", projectID: "p", createdAt: "2026-07-01T00:00:00Z", updatedAt: "2026-07-09T00:00:00Z"),
            QuestItem(id: "qst-new", content: "New", projectID: "p", createdAt: "2026-07-05T00:00:00Z", updatedAt: "2026-07-05T00:00:00Z"),
            QuestItem(id: "qst-tie-b", content: "Tie b", projectID: "p", createdAt: "2026-07-03T00:00:00Z"),
            QuestItem(id: "qst-tie-a", content: "Tie a", projectID: "p", createdAt: "2026-07-03T00:00:00Z"),
        ]
        let order = QuestDisplayState.visibleQuests(quests: quests, filter: QuestListFilter(), projectID: nil).map(\.id)
        expect(order == ["qst-new", "qst-tie-a", "qst-tie-b", "qst-old-edited"], "quests should sort newest created first, ties by id, edits not moving them: \(order)")
    }

    private static func displayRecoversDeletedSelectionToPreviousQuest() {
        let quests = [
            QuestItem(id: "qst-above", content: "Above", createdAt: "2026-07-03T03:00:00Z"),
            QuestItem(id: "qst-deleted", content: "Deleted", createdAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-below", content: "Below", createdAt: "2026-07-03T01:00:00Z"),
        ]
        let before = QuestDisplayState.visibleQuests(quests: quests, filter: QuestListFilter(), projectID: nil)
        let after = QuestDisplayState.visibleQuests(quests: [quests[0], quests[2]], filter: QuestListFilter(), projectID: nil)

        expect(
            QuestDisplayState.recoveredSelection(
                current: "qst-deleted",
                in: after,
                previouslyDisplayedQuests: before
            ) == "qst-above",
            "deleted quest should select the previous visible quest"
        )
    }

    private static let home = "/Users/me"
    private static let projects = [
        NewQuestProjectOption(projectID: "q", projectPath: "/Users/me/Code/questmaster", projectName: "questmaster"),
        NewQuestProjectOption(projectID: "s", projectPath: "/Users/me/Code/scry", projectName: "scry"),
        NewQuestProjectOption(projectID: "d", projectPath: "/Users/me/Code/dotfiles", projectName: "dotfiles"),
        NewQuestProjectOption(projectID: "m", projectPath: "/Users/me/Code/quest-maps", projectName: "maps"),
    ]

    private static func newQuestFormBuildsPayload() {
        var model = NewQuestFormModel(content: "  Ship quests  ", initialProject: projects[0], projects: projects, home: home)
        expect(model.focusedField == .content, "a prefilled project should open on the content")
        expect(model.projectText == "questmaster", "the prefill should show the project's name")
        guard let payload = model.submitPayload() else {
            fail("new quest payload was nil")
        }
        expect(payload.content == "Ship quests", "content was not trimmed")
        expect(payload.projectID == "q" && payload.projectPath == "/Users/me/Code/questmaster", "an untouched prefill should keep the opening project")

        model.focusedField = .project
        model.startProjectSearch(.seed("sc"))
        expect(model.acceptHighlightedProject(), "the matching project should be picked")
        expect(model.projectText == "scry" && model.projectMode == .select, "picking should show the name and return to SELECT")
        let picked = model.submitPayload()
        expect(picked?.projectPath == "/Users/me/Code/scry" && picked?.projectID == "" && picked?.projectName == "", "a picked project should send its path alone")
    }

    private static func newQuestFormNeedsAProjectAndContent() {
        var model = NewQuestFormModel(projects: projects, home: home)
        expect(model.focusedField == .project, "no project should open on the project field")
        expect(!model.canSubmit, "Inscribe should wait for a project and content")
        model.content = "Ship quests"
        expect(model.submitPayload() == nil && model.errorMessage == "project is required", "a missing project should say so")
        model.startProjectSearch(.seed("quest"))
        expect(!model.canSubmit, "text that names no project is no project")
        model.typeProject("scry")
        expect(model.canSubmit && model.destination == .project(projects[1]), "a project's exact name is enough")
        model.content = "  "
        expect(!model.canSubmit && model.submitPayload() == nil && model.errorMessage == "content is required", "blank content should say so")
    }

    /// The content is a prompt: Tab stays text there, as in New Session's prompt. The project field is a line, where Tab
    /// moves on.
    private static func newQuestContentKeepsTabAsText() {
        var model = NewQuestFormModel(projects: projects, home: home)
        expect(model.modalFocus == .line, "the project field should be a line, where Tab moves on")
        model.focusedField = .content
        expect(model.modalFocus == .prompt, "the content should keep Tab as text, as the New Session prompt does")
    }

    private static func projectSearchRanksByNameThenPath() {
        var model = NewQuestFormModel(projects: projects, home: home)
        model.startProjectSearch(.seed("questm"))
        expect(model.projectSuggestions.map(\.projectName) == ["questmaster"], "questm should list only the matching project: \(model.projectSuggestions.map(\.projectName))")
        expect(model.highlightedProject?.projectName == "questmaster", "the best match should be highlighted")
        model.typeProject("quest")
        expect(model.projectSuggestions.map(\.projectName) == ["questmaster", "maps"], "name matches should come before path matches")
        model.typeProject("code/do")
        expect(model.projectSuggestions.map(\.projectName) == ["dotfiles"], "the path should match too, ~-abbreviated")
        model.typeProject("")
        expect(model.projectSuggestions.count == NewQuestFormModel.maxProjectSuggestions, "an empty search should browse the projects")
    }

    private static func projectSearchSwitchesToDirectoriesForAPath() {
        var model = NewQuestFormModel(projects: projects, home: home)
        model.startProjectSearch(.seed("/"))
        expect(model.isPathText && model.showsDirectorySuggestions && !model.showsProjectSuggestions, "a / should switch to the directory suggestions")
        model.typeProject("~/Code/new")
        expect(model.isPathText && model.showsDirectorySuggestions, "a ~ should too")
        model.content = "Quest"
        let payload = model.submitPayload()
        expect(payload?.projectPath == "~/Code/new" && payload?.projectID == "", "a typed path should be sent as typed")
        model.typeProject("scr")
        expect(!model.isPathText && model.showsProjectSuggestions, "a name goes back to the projects")
    }

    private static func projectOptionsDeduplicateAndAbbreviate() {
        let options = NewQuestProjectOption.deduplicated([
            projects[0],
            NewQuestProjectOption(projectID: "q2", projectPath: "/Users/me/Code/questmaster/", projectName: "questmaster"),
            NewQuestProjectOption(projectID: "", projectPath: "", projectName: "nowhere"),
            projects[1],
        ])
        expect(options.map(\.projectID) == ["q", "s"], "one option per path, the first kept, none without a path: \(options.map(\.projectID))")
        expect(projects[0].displayPath(home: home) == "~/Code/questmaster", "home should show as ~")
        expect(NewQuestProjectOption(projectID: "", projectPath: "/Users/me", projectName: "").displayPath(home: home) == "~", "home itself is ~")
        expect(NewQuestProjectOption(projectID: "", projectPath: "/Users/meadow/x", projectName: "").displayPath(home: home) == "/Users/meadow/x", "a sibling of home keeps its path")
        expect(NewQuestProjectOption(projectID: "", projectPath: "/tmp/scratch", projectName: "").displayName == "scratch", "no name shows the folder")
    }

    private static func noProjectIsAnExplicitChoice() {
        var model = NewQuestFormModel(content: "Loose note", projects: projects, home: home)
        expect(!model.canSubmit, "an empty field is no choice, not no project")
        model.startProjectSearch(.editCurrent)
        expect(model.projectSuggestions.first == .noProject, "No project should be the first row when browsing")
        model.typeProject("no p")
        expect(model.projectMatches.first == .noProject, "typing should match No project")
        expect(model.acceptHighlightedProject(), "No project should be pickable")
        expect(model.projectText == "No project" && model.destination == .noProject, "picking it should show No project")
        expect(model.canSubmit, "No project and content are enough")
        let payload = model.submitPayload()
        expect(payload?.projectID == "" && payload?.projectPath == "" && payload?.projectName == "", "a new unfiled quest should send no project")
    }

    private static func anAssignedQuestCanBeUnfiled() {
        var edit = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        edit.focusedField = .project
        edit.startProjectSearch(.seed("No project"))
        expect(edit.acceptHighlightedProject() && edit.destination == .noProject, "precondition: No project picked")
        let payload = edit.submitPayload()
        expect(payload?.projectChanged == true && payload?.projectPath == "" && payload?.projectID == "", "assigned to unfiled should clear the project")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.data["project_changed"] == "true" && request?.data["project_path"] == "", "the edit should send project_changed with empty project fields")

        var unfiled = NewQuestFormModel(content: "Loose note", isEditing: true, projects: projects, home: home)
        expect(unfiled.projectText == "No project" && unfiled.destination == .noProject, "an unfiled quest should open on No project")
        expect(unfiled.canSubmit && unfiled.submitPayload()?.projectChanged == false, "unfiled staying unfiled should send content only")
    }

    private static func browsingReachesEveryProject() {
        var model = NewQuestFormModel(projects: projects, home: home)
        model.startProjectSearch(.editCurrent)
        expect(model.projectMatches.count == projects.count + 1, "browsing should list No project and every project")
        for _ in 0..<4 {
            model.moveProjectHighlight(1)
        }
        expect(model.highlightedProject == projects[3], "↓ should reach projects past the first three")
        expect(model.projectSuggestions == Array(projects[1...3]) && model.visibleProjectHighlightIndex == 2, "the rows should scroll with the highlight")
    }

    private static func leavingTheProjectFieldEndsItsSearch() {
        var model = NewQuestFormModel(projects: projects, home: home)
        model.startProjectSearch(.seed("scr"))
        model.moveFocus(1)
        expect(model.projectMode == .select && model.projectText == "scr", "leaving by ⌃j should end the search and keep the text")
        model.moveFocus(-1)
        expect(model.focusedField == .project && model.projectMode == .select, "coming back should be in SELECT")
    }

    private static func editQuestKeepsItsProjectUnlessItChanges() {
        var unfiled = NewQuestFormModel(content: "Loose note", isEditing: true, projects: projects, home: home)
        expect(unfiled.canSubmit, "an edit can keep a quest that has no project")
        expect(unfiled.submitPayload()?.projectChanged == false, "an untouched project should send content only")

        var edit = NewQuestFormModel(content: "Quest", initialProject: projects[1], isEditing: true, projects: projects, home: home)
        expect(edit.submitPayload()?.projectChanged == false, "an unchanged project should be left alone")
        edit.focusedField = .project
        edit.startProjectSearch(.seed("dot"))
        edit.acceptHighlightedProject()
        let moved = edit.submitPayload()
        expect(moved?.projectChanged == true && moved?.projectPath == "/Users/me/Code/dotfiles", "another project should move the quest")
        edit.startProjectSearch(.seed("x"))
        edit.endProjectSearch(keepingText: false)
        expect(edit.projectText == "dotfiles", "Esc should restore the text the search started from")
        edit.typeProject("")
        expect(!edit.canSubmit, "clearing a filed quest's project needs a new one")
    }

    private static func startFromQuestsBuildsIDPromptAndRejectsMixedProjects() {
        let quests = [
            QuestItem(id: "qst-one", content: "First\nline", projectID: "repo", projectPath: "/tmp/repo"),
            QuestItem(id: "-urgent", content: "Urgent", projectID: "repo", projectPath: "/tmp/repo"),
            QuestItem(id: "qst two", content: "Second", projectID: "repo", projectPath: "/tmp/repo"),
            QuestItem(id: "qst'three", content: "Third", projectID: "repo", projectPath: "/tmp/repo"),
        ]
        do {
            let request = try ServeMutationRequests.startFromQuests(quests, title: "quests", agent: "codex")
            let data = request.jsonObject(id: "start")["data"] as? NSDictionary
            expect(data?["cwd"] as? String == "/tmp/repo", "cwd mismatch")
            expect(data?["prompt"] as? String == "Quest IDs: qst-one -urgent 'qst two' 'qst'\\''three'\nRead them with: questmaster quest ls -- qst-one -urgent 'qst two' 'qst'\\''three'", "start prompt should instruct agents to read the quest IDs")
            expect(data?["quest_ids"] == nil, "start should send the editable prompt through the existing prompt field")
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
