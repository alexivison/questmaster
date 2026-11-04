import Foundation
import QuestmasterCore

struct ProjectSettingsTests {
    static func run() {
        cursorMovesAndHoldsAtTheEnds()
        arrangementMovesTheHighlightedRowAndHoldsAtTheEnds()
        arrangementIsDirtyOnlyWhileTheOrderDiffers()
        arrangementSendsTheWholeOrderOnlyWhenDirty()
        arrangementClampsItsStartingHighlight()
        arrangementReturnsTheSnapshotsProjectsInArrangedOrder()
        projectRowLooksFillWhileArrangingOrHighlighted()
        editingAProjectWithoutAnOverrideShowsNoName()
        editingSendsOnlyTheFieldsThatChanged()
        editingClearsTheNameAndColourWithEmptyStrings()
        editingWithNoChangeSendsNothing()
        addingRequiresAPath()
        addingSendsThePathAndOnlyTheNameAndColourGiven()
        pathShortensTheHomeDirectoryAtAComponentBoundary()
        print("ProjectSettingsTests: all tests passed")
    }

    private static let projects = [
        TrackerProject(id: "repo-a", name: "alpha", defaultName: "alpha", path: "/Users/dev/Code/alpha", color: "blue"),
        TrackerProject(id: "repo-b", name: "beta", defaultName: "beta", path: "/Users/dev/Code/beta", color: ""),
        TrackerProject(id: "repo-c", name: "Gamma", defaultName: "gamma", path: "/Users/dev/Code/gamma", color: "green"),
    ]

    private static func cursorMovesAndHoldsAtTheEnds() {
        expect(ProjectListCursor.moved(from: 0, by: 1, count: 3) == 1, "down should move one row")
        expect(ProjectListCursor.moved(from: 2, by: 1, count: 3) == 2, "down should hold at the last row")
        expect(ProjectListCursor.moved(from: 0, by: -1, count: 3) == 0, "up should hold at the first row")
        expect(ProjectListCursor.moved(from: 5, by: 0, count: 3) == 2, "an index past the end should clamp to the last row")
        expect(ProjectListCursor.moved(from: 1, by: 1, count: 0) == 0, "an empty list should hold at zero")
    }

    private static func arrangementMovesTheHighlightedRowAndHoldsAtTheEnds() {
        var arrangement = ProjectArrangement(projectIDs: ["a", "b", "c"], highlight: 0)
        arrangement.moveHighlightedRow(by: 1)
        expect(arrangement.projectIDs == ["b", "a", "c"], "moving down should swap the row with the one below")
        expect(arrangement.highlight == 1, "the highlight should follow the moved row")
        arrangement.moveHighlightedRow(by: -1)
        expect(arrangement.projectIDs == ["a", "b", "c"], "moving up should swap the row back")
        expect(arrangement.highlight == 0, "the highlight should follow the row back up")
        arrangement.moveHighlightedRow(by: -1)
        expect(arrangement.projectIDs == ["a", "b", "c"] && arrangement.highlight == 0, "moving the first row up should do nothing")
        arrangement.setHighlight(2)
        arrangement.moveHighlightedRow(by: 1)
        expect(arrangement.projectIDs == ["a", "b", "c"], "moving the last row down should do nothing")
    }

    private static func arrangementIsDirtyOnlyWhileTheOrderDiffers() {
        var arrangement = ProjectArrangement(projectIDs: ["a", "b"], highlight: 0)
        expect(!arrangement.isDirty, "a fresh arrangement should be clean")
        arrangement.moveHighlightedRow(by: 1)
        expect(arrangement.isDirty, "a moved row should make the arrangement dirty")
        arrangement.moveHighlightedRow(by: -1)
        expect(!arrangement.isDirty, "moving the row back should make the arrangement clean again")
    }

    private static func arrangementSendsTheWholeOrderOnlyWhenDirty() {
        var arrangement = ProjectArrangement(projectIDs: ["a", "b", "c"], highlight: 2)
        do {
            let clean = try arrangement.reorderRequest()
            expect(clean == nil, "a clean arrangement should send nothing")
            arrangement.moveHighlightedRow(by: -1)
            let request = try arrangement.reorderRequest()
            expect(request?.method == "project.reorder", "a dirty arrangement should send project.reorder")
            expect(request?.lists["project_ids"] == ["a", "c", "b"], "the reorder should carry the full arranged order")
        } catch {
            fail("reorder request threw: \(error)")
        }
    }

    private static func arrangementClampsItsStartingHighlight() {
        let arrangement = ProjectArrangement(projectIDs: ["a", "b"], highlight: 9)
        expect(arrangement.highlight == 1, "a starting highlight past the end should clamp to the last row")
        expect(ProjectArrangement(projectIDs: [], highlight: 3).highlight == 0, "an empty arrangement should keep the highlight at zero")
    }

    private static func arrangementReturnsTheSnapshotsProjectsInArrangedOrder() {
        var arrangement = ProjectArrangement(projectIDs: ["repo-a", "repo-b", "repo-c"], highlight: 0)
        arrangement.moveHighlightedRow(by: 1)
        expect(arrangement.projects(from: projects).map(\.id) == ["repo-b", "repo-a", "repo-c"], "the arranged rows should follow the arranged order")
        let shrunk = ProjectArrangement(projectIDs: ["repo-c", "gone", "repo-a"], highlight: 0)
        expect(shrunk.projects(from: projects).map(\.id) == ["repo-c", "repo-a"], "a project the snapshot no longer lists should drop out")
        arrangement.setHighlight(7)
        expect(arrangement.highlight == 2, "setHighlight should clamp into the rows")
    }

    private static func editingAProjectWithoutAnOverrideShowsNoName() {
        let draft = ProjectEditDraft.editing(projects[0])
        expect(draft.name.isEmpty && draft.initialName.isEmpty, "a project named after its folder should show the placeholder, not a name")
        expect(draft.defaultName == "alpha", "the placeholder should be the folder's name")
        expect(draft.color == "blue" && draft.path == "/Users/dev/Code/alpha", "the draft should start from the project's colour and path")
        let overridden = ProjectEditDraft.editing(projects[2])
        expect(overridden.name == "Gamma" && overridden.initialName == "Gamma", "a renamed project should show its override")
    }

    private static func editingSendsOnlyTheFieldsThatChanged() {
        var draft = ProjectEditDraft.editing(projects[0])
        draft.color = "red"
        do {
            let request = try draft.saveRequest()
            expect(request?.method == "project.update", "a recolour should send project.update")
            expect(request?.data["project_id"] == "repo-a" && request?.data["color"] == "red", "a recolour should send the project and its new colour")
            expect(request?.data["name"] == nil, "an unchanged name should be left out of the update")
        } catch {
            fail("recolour request threw: \(error)")
        }
        var renamed = ProjectEditDraft.editing(projects[1])
        renamed.name = "  Beta Site "
        do {
            let request = try renamed.saveRequest()
            expect(request?.data["name"] == "Beta Site", "a rename should send the trimmed name")
            expect(request?.data["color"] == nil, "an unchanged colour should be left out of the update")
        } catch {
            fail("rename request threw: \(error)")
        }
    }

    private static func editingClearsTheNameAndColourWithEmptyStrings() {
        var draft = ProjectEditDraft.editing(projects[2])
        draft.name = "   "
        draft.color = ""
        do {
            let request = try draft.saveRequest()
            expect(request?.data["name"] == "", "a cleared name should send an empty string to revert to the folder's")
            expect(request?.data["color"] == "", "a cleared colour should send an empty string")
        } catch {
            fail("clear request threw: \(error)")
        }
    }

    private static func editingWithNoChangeSendsNothing() {
        do {
            let first = try ProjectEditDraft.editing(projects[0]).saveRequest()
            let second = try ProjectEditDraft.editing(projects[2]).saveRequest()
            expect(first == nil, "an edit that changed nothing should send nothing")
            expect(second == nil, "an overridden name left alone should send nothing")
        } catch {
            fail("unchanged edit threw: \(error)")
        }
    }

    private static func addingRequiresAPath() {
        var draft = ProjectEditDraft.adding()
        draft.name = "Scratch"
        do {
            _ = try draft.saveRequest()
            fail("adding without a path should throw")
        } catch let error as ServeMutationRequestError {
            expect(error == .missing("path"), "adding without a path should name the path as missing")
        } catch {
            fail("unexpected error: \(error)")
        }
    }

    private static func addingSendsThePathAndOnlyTheNameAndColourGiven() {
        do {
            var draft = ProjectEditDraft.adding()
            draft.path = "~/Code/scratch"
            let bare = try draft.saveRequest()
            expect(bare?.method == "project.add" && bare?.data["path"] == "~/Code/scratch", "adding should send project.add with the path")
            expect(bare?.data["name"] == nil && bare?.data["color"] == nil, "a blank name and colour should be left out of an add")
            draft.name = "Scratch"
            draft.color = "Violet"
            let named = try draft.saveRequest()
            expect(named?.data["name"] == "Scratch" && named?.data["color"] == "violet", "an add should send the given name and colour")
        } catch {
            fail("add request threw: \(error)")
        }
    }

    private static func pathShortensTheHomeDirectoryAtAComponentBoundary() {
        let home = "/Users/dev"
        expect(ProjectPathDisplay.shortened("/Users/dev", homeDirectory: home) == "~", "the home directory itself should show as ~")
        expect(ProjectPathDisplay.shortened("/Users/dev/Code/alpha", homeDirectory: home) == "~/Code/alpha", "a path under home should show from ~")
        expect(ProjectPathDisplay.shortened("/Users/devops/Code", homeDirectory: home) == "/Users/devops/Code", "a sibling sharing the home's prefix should not shorten")
        expect(ProjectPathDisplay.shortened("/opt/tools", homeDirectory: home) == "/opt/tools", "a path outside home should show unchanged")
        expect(ProjectPathDisplay.shortened("/Users/dev/Code", homeDirectory: "/Users/dev/") == "~/Code", "a home with a trailing slash should shorten the same way")
    }

    private static func projectRowLooksFillWhileArrangingOrHighlighted() {
        expect(RowLook.project(highlighted: false, arranging: false) == .projectRest, "a resting project row should have no fill")
        expect(RowLook.project(highlighted: true, arranging: false) == .projectCursor, "the highlighted project row should take the cursor look")
        expect(RowLook.project(highlighted: false, arranging: true) == .projectArranged, "every arranged row should be filled")
        expect(RowLook.project(highlighted: true, arranging: true) == .projectCursor, "the arranged cursor row should keep the cursor look")
        expect(RowLook.projectCursor.outline == .controlBorder && RowLook.projectCursor.fill == .item, "the cursor look should be filled and outlined in controlBorder")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ProjectSettingsTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
