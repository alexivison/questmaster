import Foundation
import QuestmasterCore

struct TrackerRecolorLogicTests {
    static func run() {
        swatchesMatchDisplayColors()
        sessionScopeBuildsRecolorRequest()
        repoScopeCanClearWithEmptyColor()
        pickerStateRequiresTheRequestedScope()
        inlineSessionEditCyclesAndConfirms()
        inlineRepoEditCyclesBackwardAndCancels()
        emptyColorIsPreservedInMutationData()
        print("TrackerRecolorLogicTests: all tests passed")
    }

    private static func swatchesMatchDisplayColors() {
        let names = TrackerRecolorPickerState.swatches.map(\.name)
        expect(names == [
            "blue",
            "green",
            "yellow",
            "magenta",
            "cyan",
            "red",
            "orange",
            "gold",
            "lime",
            "teal",
            "sky",
            "indigo",
            "violet",
            "pink",
        ], "swatch names mismatch: \(names)")
        expect(TrackerRecolorPickerState.swatches.map(\.cssVariable).allSatisfy { $0.hasPrefix("--c-") }, "swatches should expose --c-* names")
    }

    private static func sessionScopeBuildsRecolorRequest() {
        let target = TrackerRecolorTarget(
            sessionID: "qm-a",
            role: "standalone",
            repoIdentity: "/repo/.git",
            displayColor: "magenta",
            repoColor: "green"
        )
        guard var state = TrackerRecolorPickerState(target: target, preferredScope: .session) else {
            fail("session target did not create picker state")
        }
        expect(state.scope == .session, "scope = \(state.scope), want session")
        expect(state.selectedSwatch?.name == "magenta", "selected swatch = \(String(describing: state.selectedSwatch?.name)), want magenta")
        state.selectColor(named: "violet")

        do {
            let request = try state.selectedColorRequest()
            let object = request.jsonObject(id: "recolor") as NSDictionary
            expect(object["method"] as? String == "recolor", "method mismatch")
            let data = object["data"] as? NSDictionary
            expect(data?["scope"] as? String == "session", "scope missing")
            expect(data?["session_id"] as? String == "qm-a", "session_id missing")
            expect(data?["color"] as? String == "violet", "color missing")
        } catch {
            fail("session request threw \(error)")
        }
    }

    private static func repoScopeCanClearWithEmptyColor() {
        let target = TrackerRecolorTarget(
            sessionID: "qm-a",
            role: "standalone",
            repoIdentity: "/repo/.git",
            displayColor: "magenta",
            repoColor: "green"
        )
        guard let state = TrackerRecolorPickerState(target: target, preferredScope: .repo) else {
            fail("repo target did not create picker state")
        }
        expect(state.scope == .repo, "scope = \(state.scope), want repo")
        expect(state.selectedSwatch?.name == "green", "repo selected swatch = \(String(describing: state.selectedSwatch?.name)), want green")

        do {
            let request = try state.clearRequest()
            let object = request.jsonObject(id: "clear") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(data?["scope"] as? String == "repo", "repo scope missing")
            expect(data?["repo_identity"] as? String == "/repo/.git", "repo identity missing")
            expect(data?["color"] as? String == "", "empty clear color was not preserved")
        } catch {
            fail("repo clear request threw \(error)")
        }
    }

    private static func pickerStateRequiresTheRequestedScope() {
        let target = TrackerRecolorTarget(
            sessionID: "qm-worker",
            role: "worker",
            repoIdentity: "/repo/.git",
            displayColor: "cyan",
            repoColor: "pink"
        )
        expect(!target.isSessionScopeAvailable, "worker session scope should be unavailable")
        expect(TrackerRecolorPickerState(target: target, preferredScope: .session) == nil, "session key should not fall back to repo scope")

        guard let state = TrackerRecolorPickerState(target: target, preferredScope: .repo) else {
            fail("worker repo target did not create picker state")
        }
        expect(state.scope == .repo, "repo key should open repo scope")

        let looseWorker = TrackerRecolorTarget(
            sessionID: "qm-worker",
            role: "worker",
            repoIdentity: "",
            displayColor: "cyan",
            repoColor: ""
        )
        expect(TrackerRecolorPickerState(target: looseWorker, preferredScope: .session) == nil, "worker without repo should have no recolor target")
    }

    private static func inlineSessionEditCyclesAndConfirms() {
        let target = TrackerRecolorTarget(
            sessionID: "qm-a",
            role: "standalone",
            repoIdentity: "/repo/.git",
            displayColor: "magenta",
            repoColor: "green"
        )
        guard var state = TrackerInlineRecolorState(target: target, preferredScope: .session) else {
            fail("session target did not create inline edit state")
        }

        expect(state.scope == .session, "inline edit scope = \(state.scope), want session")
        expect(state.previewColor == "magenta", "initial preview = \(state.previewColor), want magenta")
        expect(tryEffect { try state.handle(.right) } == .preview(color: "cyan"), "right cycle should preview cyan")
        expect(state.previewColor == "cyan", "right cycle state preview = \(state.previewColor), want cyan")
        expect(tryEffect { try state.handle(.left) } == .preview(color: "magenta"), "left cycle should preview magenta")
        expect(tryEffect { try state.handle(.left) } == .preview(color: "yellow"), "left cycle should preview yellow")

        guard case .confirm(let request) = tryEffect({ try state.handle(.confirm) }) else {
            fail("confirm did not produce a recolor request")
        }
        let object = request.jsonObject(id: "inline") as NSDictionary
        let data = object["data"] as? NSDictionary
        expect(object["method"] as? String == "recolor", "inline method mismatch")
        expect(data?["scope"] as? String == "session", "inline session scope missing")
        expect(data?["session_id"] as? String == "qm-a", "inline session id missing")
        expect(data?["color"] as? String == "yellow", "inline session color missing")
        expect(state.mutationLabel == "recolor session qm-a", "inline session label mismatch")
    }

    private static func inlineRepoEditCyclesBackwardAndCancels() {
        let target = TrackerRecolorTarget(
            sessionID: "qm-a",
            role: "standalone",
            repoIdentity: "/repo/.git",
            displayColor: "magenta",
            repoColor: "green"
        )
        guard var state = TrackerInlineRecolorState(target: target, preferredScope: .repo) else {
            fail("repo target did not create inline edit state")
        }

        expect(state.scope == .repo, "inline repo scope = \(state.scope), want repo")
        expect(state.previewColor == "green", "initial repo preview = \(state.previewColor), want green")
        expect(tryEffect { try state.handle(.left) } == .preview(color: "blue"), "left cycle should preview blue")
        expect(state.previewColor == "blue", "left cycle repo preview = \(state.previewColor), want blue")
        expect(tryEffect { try state.handle(.cancel) } == .cancel, "cancel should not produce a request")
        expect(state.previewColor == "green", "cancel should revert preview to green")
        expect(state.mutationLabel == "recolor repo color", "inline repo label mismatch")
    }

    private static func emptyColorIsPreservedInMutationData() {
        let request = ServeMutationRequest(method: "recolor", data: ["scope": "session", "session_id": "qm-a", "color": " "])
        let object = request.jsonObject(id: "clear") as NSDictionary
        let data = object["data"] as? NSDictionary
        expect(data?["color"] as? String == "", "ServeMutationRequest dropped empty color")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func tryEffect(_ body: () throws -> TrackerInlineRecolorEffect) -> TrackerInlineRecolorEffect? {
        do {
            return try body()
        } catch {
            fail("inline recolor effect threw \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerRecolorLogicTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
