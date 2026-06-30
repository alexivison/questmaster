import Foundation
import QuestmasterCore

struct ShellChromeTests {
    static func run() {
        regionTabsReflectFocusAndVisibility()
        regionTabsOrderMapsToRegions()
        servePillDisplayCopyAndIndicator()
        dockTopBarBoardListShowsSectionTabs()
        dockTopBarQuestDetailShowsBackAndTitle()
        dockTopBarArtifactListHasNoBackOrActions()
        dockTopBarArtifactViewerShowsBackTitleAndActions()
        print("ShellChromeTests: all tests passed")
    }

    private static func regionTabsReflectFocusAndVisibility() {
        let segments = ShellRegionTabs.segments(
            for: AppNavigationState(focusedRegion: .terminal, trackerVisible: true, dockVisible: false)
        )
        expect(segments.count == 3, "expected three region segments")
        expect(segments[0] == ShellPillSegment(title: "Tracker", isActive: false, isStruck: false), "tracker visible+unfocused mismatch")
        expect(segments[1] == ShellPillSegment(title: "Terminal", isActive: true), "terminal should be active")
        expect(segments[2] == ShellPillSegment(title: "Dock", isActive: false, isStruck: true), "hidden dock should be struck")

        let dockFocused = ShellRegionTabs.segments(
            for: AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        )
        expect(dockFocused[0].isStruck, "hidden tracker should be struck")
        expect(!dockFocused[0].isActive, "hidden tracker cannot be active")
        expect(dockFocused[2].isActive && !dockFocused[2].isStruck, "visible focused dock should be active, not struck")
    }

    private static func regionTabsOrderMapsToRegions() {
        expect(ShellRegionTabs.order == [.tracker, .terminal, .dock], "region tab order must stay tracker/terminal/dock")
    }

    private static func servePillDisplayCopyAndIndicator() {
        expect(ServePillDisplay.make(.ready) == ServePillDisplay(label: "serve", indicator: .dot), "ready pill mismatch")
        expect(ServePillDisplay.make(.starting) == ServePillDisplay(label: "starting serve…", indicator: .spinner), "starting pill should spin")
        expect(ServePillDisplay.make(.error) == ServePillDisplay(label: "serve error", indicator: .dot), "error pill mismatch")
    }

    private static func dockTopBarBoardListShowsSectionTabs() {
        let model = DockTopBarModel.make(
            snapshot: nil,
            selectedSection: .active,
            mode: .board,
            questRoute: .list,
            questTitle: nil,
            artifactRoute: .list,
            artifactTitle: nil
        )
        expect(model.back == nil, "board list should have no back affordance")
        expect(model.title == nil, "board list should not show a title")
        expect(model.showSectionTabs, "board list should show section tabs")
        expect(!model.showArtifactActions, "board list should not show artifact actions")
        expect(model.sectionSegments.map(\.title) == ["Drafts 0", "Active 0", "Done 0"], "empty board section titles mismatch")
        expect(model.sectionSegments.map(\.isActive) == [false, true, false], "selected section should be the active segment")
    }

    private static func dockTopBarQuestDetailShowsBackAndTitle() {
        let model = DockTopBarModel.make(
            snapshot: nil,
            selectedSection: .drafts,
            mode: .board,
            questRoute: .detail,
            questTitle: "Ship the thing",
            artifactRoute: .list,
            artifactTitle: nil
        )
        expect(model.back == .questList, "quest detail back should target the quest list")
        expect(model.title == "Ship the thing", "quest detail should show the quest title")
        expect(!model.showSectionTabs, "quest detail should hide section tabs")
        expect(model.sectionSegments.isEmpty, "quest detail should carry no section segments")

        let untitled = DockTopBarModel.make(
            snapshot: nil, selectedSection: .drafts, mode: .board,
            questRoute: .detail, questTitle: nil, artifactRoute: .list, artifactTitle: nil
        )
        expect(untitled.title == "Quest detail", "missing quest title should fall back to a default")
    }

    private static func dockTopBarArtifactListHasNoBackOrActions() {
        let model = DockTopBarModel.make(
            snapshot: nil,
            selectedSection: .drafts,
            mode: .artifacts,
            questRoute: .list,
            questTitle: nil,
            artifactRoute: .list,
            artifactTitle: nil
        )
        expect(model.back == nil, "artifact list should have no back affordance")
        expect(model.title == "Artifacts", "artifact list should show the Artifacts title")
        expect(!model.showSectionTabs, "artifact mode never shows section tabs")
        expect(!model.showArtifactActions, "artifact list should not show artifact actions")
    }

    private static func dockTopBarArtifactViewerShowsBackTitleAndActions() {
        let model = DockTopBarModel.make(
            snapshot: nil,
            selectedSection: .drafts,
            mode: .artifacts,
            questRoute: .list,
            questTitle: nil,
            artifactRoute: .viewer,
            artifactTitle: "report.html"
        )
        expect(model.back == .artifactList, "artifact viewer back should target the artifact list")
        expect(model.title == "report.html", "artifact viewer should show the artifact title")
        expect(model.showArtifactActions, "artifact viewer should show copy/refresh actions")

        let untitled = DockTopBarModel.make(
            snapshot: nil, selectedSection: .drafts, mode: .artifacts,
            questRoute: .list, questTitle: nil, artifactRoute: .viewer, artifactTitle: nil
        )
        expect(untitled.title == "Artifact", "missing artifact title should fall back to a default")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ShellChromeTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
