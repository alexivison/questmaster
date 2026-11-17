import Foundation
import QuestmasterCore

struct ShellChromeTests {
    static func run() {
        dockTopBarArtifactListHasNoBackOrActions()
        dockTopBarArtifactViewerShowsBackTitleAndActions()
        dockTopBarWorkerChatShowsItsTitle()
        dockTopBarWatcherShowsItsTitle()
        dockTopBarOnlyTheArtifactListShowsScopeTabs()
        print("ShellChromeTests: all tests passed")
    }

    /// The Session/All tabs sit in the artifact list's top bar and nowhere else: not in the viewer's bar, the Worker Log's,
    /// or Watcher's, so those bars keep their 40pt band as before.
    private static func dockTopBarOnlyTheArtifactListShowsScopeTabs() {
        let list = DockTopBarModel.make(mode: .artifacts, artifactRoute: .list, artifactTitle: nil, logAttached: false, artifactScope: .all)
        expect(list.artifactScope == .all, "the artifact list's top bar should show the tabs, with the scope selected")
        let viewer = DockTopBarModel.make(mode: .artifacts, artifactRoute: .viewer, artifactTitle: "report.html", logAttached: false, artifactScope: .all)
        expect(viewer.artifactScope == nil, "the artifact viewer's top bar should show no tabs")
        let workerLog = DockTopBarModel.make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil, logAttached: true, artifactScope: .all)
        expect(workerLog.artifactScope == nil, "the Worker Log's top bar should show no tabs")
        expect(DockTopBarModel.watcher.artifactScope == nil, "Watcher's top bar should show no tabs")
        let unset = DockTopBarModel.make(mode: .artifacts, artifactRoute: .list, artifactTitle: nil, logAttached: false)
        expect(unset.artifactScope == nil, "a list with no scope given should show no tabs")
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

    private static func dockTopBarWatcherShowsItsTitle() {
        let model = DockTopBarModel.watcher
        expect(model.title == "Watcher", "watcher should show its own title")
        expect(model.back == nil && !model.showArtifactActions, "watcher has no back affordance or artifact actions")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ShellChromeTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
