import Foundation
import QuestmasterCore

struct ShellChromeTests {
    static func run() {
        dockTopBarArtifactListHasNoBackOrActions()
        dockTopBarArtifactViewerShowsBackTitleAndActions()
        dockTopBarWorkerChatShowsItsTitle()
        dockTopBarVersionControlShowsItsTitle()
        print("ShellChromeTests: all tests passed")
    }

    private static func dockTopBarArtifactListHasNoBackOrActions() {
        let model = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .list,
            artifactTitle: nil,
            logAttached: false
        )
        expect(model.back == nil, "artifact list should have no back affordance")
        expect(model.title == "Artifacts", "artifact list should show the Artifacts title")
        expect(!model.showArtifactActions, "artifact list should not show artifact actions")
    }

    private static func dockTopBarArtifactViewerShowsBackTitleAndActions() {
        let model = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .viewer,
            artifactTitle: "report.html",
            logAttached: false
        )
        expect(model.back == .artifactList, "artifact viewer back should target the artifact list")
        expect(model.title == "report.html", "artifact viewer should show the artifact title")
        expect(model.showArtifactActions, "artifact viewer should show copy/refresh actions")

        let untitled = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .viewer,
            artifactTitle: nil,
            logAttached: false
        )
        expect(untitled.title == "Artifact", "missing artifact title should fall back to a default")
    }

    private static func dockTopBarWorkerChatShowsItsTitle() {
        let model = DockTopBarModel.make(mode: .workerChat, artifactRoute: .viewer, artifactTitle: "report.html", logAttached: true)
        expect(model.title == "Worker Log", "worker log should show its own title")
        expect(model.back == nil, "worker chat has no back affordance")
        expect(!model.showArtifactActions, "worker chat should not show artifact actions")
        expect(model.showsLogFilter, "the worker log attached to a master should show its filter")
        let detached = DockTopBarModel.make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil, logAttached: false)
        expect(!detached.showsLogFilter && detached.title == "Worker Log", "a worker log with no master has no filter to open, but keeps its title")
        let artifacts = DockTopBarModel.make(mode: .artifacts, artifactRoute: .list, artifactTitle: nil, logAttached: true)
        expect(!artifacts.showsLogFilter, "the artifact dock has no log filter, attached or not")
    }

    private static func dockTopBarVersionControlShowsItsTitle() {
        let model = DockTopBarModel.versionControl
        expect(model.title == "Version Control", "version control should show its own title")
        expect(model.back == nil && !model.showArtifactActions, "version control has no back affordance or artifact actions")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ShellChromeTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
