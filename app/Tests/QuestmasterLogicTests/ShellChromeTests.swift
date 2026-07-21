import Foundation
import QuestmasterCore

struct ShellChromeTests {
    static func run() {
        dockTopBarArtifactListHasNoBackOrActions()
        dockTopBarArtifactViewerShowsBackTitleAndActions()
        print("ShellChromeTests: all tests passed")
    }

    private static func dockTopBarArtifactListHasNoBackOrActions() {
        let model = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .list,
            artifactTitle: nil
        )
        expect(model.back == nil, "artifact list should have no back affordance")
        expect(model.title == "Artifacts", "artifact list should show the Artifacts title")
        expect(!model.showArtifactActions, "artifact list should not show artifact actions")
    }

    private static func dockTopBarArtifactViewerShowsBackTitleAndActions() {
        let model = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .viewer,
            artifactTitle: "report.html"
        )
        expect(model.back == .artifactList, "artifact viewer back should target the artifact list")
        expect(model.title == "report.html", "artifact viewer should show the artifact title")
        expect(model.showArtifactActions, "artifact viewer should show copy/refresh actions")

        let untitled = DockTopBarModel.make(
            mode: .artifacts,
            artifactRoute: .viewer,
            artifactTitle: nil
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
