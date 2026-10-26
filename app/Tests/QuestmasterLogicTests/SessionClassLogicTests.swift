import Foundation
import QuestmasterCore

struct SessionClassLogicTests {
    static func run() {
        classesAreTheBackendsInItsOrder()
        displayNamesAreCapitalised()
        classIDsParseLeniently()
        classCycleWrapsWithoutRandom()
        classCycleCountsRandomAsASlot()
        portraitNamesCarryTheirKindBecauseResourcesFlatten()
        trackerPortraitsFollowRoleAndClass()
        newSessionStartsOnRandomAndCyclesThroughEveryClass()
        newSessionSendsAClassOnlyWhenOneIsChosen()
        newSessionClassIsFrozenWhileSubmitting()
        classKeyIsControlEInTheTitleFieldOnly()
        editPortraitIsEditableForMastersOnly()
        editPortraitCyclesTheMastersClassAndLeavesTheRestAlone()
        editSavesAReclassOnlyWhenTheClassChanged()
        anUnassignedMasterIsEditableAndStartsAtThePaladin()
        editPortraitNamesItselfForAssistiveTechnology()
        startRequestEncodesAClassOnlyWhenChosen()
        reclassRequestEncodesTheSessionAndClass()
        print("SessionClassLogicTests: all tests passed")
    }

    private static func classesAreTheBackendsInItsOrder() {
        expect(
            SessionClass.allCases.map(\.rawValue) == ["paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard"],
            "the ids and their order are the backend's (internal/state/session_class.go)"
        )
    }

    private static func displayNamesAreCapitalised() {
        expect(SessionClass.cleric.displayName == "Cleric", "the display name is the id, capitalised")
        expect(SessionClass.allCases.allSatisfy { $0.displayName.first?.isUppercase == true }, "every display name starts with a capital")
        expect(SessionClass.randomLabel == "Random", "the default's label")
    }

    private static func classIDsParseLeniently() {
        expect(SessionClass(id: "wizard") == .wizard, "an id parses")
        expect(SessionClass(id: " Druid ") == .druid, "case and whitespace don't matter")
        expect(SessionClass(id: "") == nil, "an empty class is no class")
        expect(SessionClass(id: "ranger") == nil, "an unknown class is no class")
    }

    private static func classCycleWrapsWithoutRandom() {
        expect(SessionClass.paladin.next == .wizard, "paladin is followed by wizard")
        expect(SessionClass.bard.next == .paladin, "bard wraps to paladin: an edit has no Random")
        var visited: [SessionClass] = [.paladin]
        for _ in 1..<SessionClass.allCases.count {
            visited.append(visited[visited.count - 1].next)
        }
        expect(visited == SessionClass.allCases, "cycling forward visits every class in order")
    }

    private static func classCycleCountsRandomAsASlot() {
        expect(SessionClass.next(after: nil) == .paladin, "Random is followed by paladin")
        expect(SessionClass.next(after: .rogue) == .cleric, "a class is followed by the next")
        expect(SessionClass.next(after: .bard) == nil, "bard is followed by Random")
        var choice: SessionClass? = nil
        var seen: [SessionClass?] = []
        for _ in 0...SessionClass.allCases.count {
            choice = SessionClass.next(after: choice)
            seen.append(choice)
        }
        expect(seen == SessionClass.allCases.map { Optional($0) } + [nil], "one full lap is Random, the seven classes, Random")
    }

    private static func portraitNamesCarryTheirKindBecauseResourcesFlatten() {
        expect(SessionPortrait.master(.paladin).resourceName == "class-paladin", "a master portrait is class-<id>")
        expect(SessionPortrait.familiar(.paladin).resourceName == "familiar-paladin", "a familiar is familiar-<id>")
        expect(SessionPortrait.master(nil).resourceName == "random", "the Random silhouette")
        let names = SessionClass.allCases.flatMap { [SessionPortrait.master($0).resourceName, SessionPortrait.familiar($0).resourceName] }
            + [SessionPortrait.master(nil).resourceName]
        expect(Set(names).count == names.count, "no two portraits share a bundle name, or the flattened bundle would keep one")
    }

    private static func trackerPortraitsFollowRoleAndClass() {
        func session(role: String, sessionClass: String) -> TrackerSession {
            TrackerSession(id: "qm-1", title: "t", repoName: "r", sessionClass: sessionClass, role: role)
        }
        expect(SessionPortrait(session: session(role: "master", sessionClass: "cleric")) == .master(.cleric), "a master shows its class")
        expect(SessionPortrait(session: session(role: "worker", sessionClass: "cleric")) == .familiar(.cleric), "a worker shows its master's familiar")
        expect(SessionPortrait(session: session(role: "master", sessionClass: "")) == nil, "a master without a class falls back to the logo disc")
        expect(SessionPortrait(session: session(role: "worker", sessionClass: "ranger")) == nil, "an unknown class falls back to the logo disc")
        for role in ["shell", "tmux", "orphan"] {
            expect(SessionPortrait(session: session(role: role, sessionClass: "bard")) == nil, "a \(role) row has no portrait")
        }
    }

    private static func newSessionStartsOnRandomAndCyclesThroughEveryClass() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        expect(model.sessionClass == nil && model.classLabel == "Random", "New Session defaults to Random")
        model.cycleSessionClass()
        expect(model.sessionClass == .paladin && model.classLabel == "Paladin", "the first cycle is paladin")
        for _ in 1..<SessionClass.allCases.count {
            model.cycleSessionClass()
        }
        expect(model.sessionClass == .bard && model.classLabel == "Bard", "six more cycles reach bard")
        model.cycleSessionClass()
        expect(model.sessionClass == nil && model.classLabel == "Random", "bard is followed by Random")
    }

    private static func newSessionSendsAClassOnlyWhenOneIsChosen() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        expect(model.submitPayload()?.sessionClass == nil, "Random sends no class")
        model.cycleSessionClass()
        model.cycleSessionClass()
        expect(model.submitPayload()?.sessionClass == .wizard, "a chosen class is in the payload")
    }

    private static func newSessionClassIsFrozenWhileSubmitting() {
        var model = NewSessionFormModel(initialPath: "/tmp/project")
        model.setSubmitting(true)
        model.cycleSessionClass()
        expect(model.sessionClass == nil, "the class stays put while Summon is in flight")
    }

    private static func classKeyIsControlEInTheTitleFieldOnly() {
        func cycles(control: Bool = true, command: Bool = false, option: Bool = false, keyCode: UInt16 = 14, titleFocused: Bool = true) -> Bool {
            SessionClassKey.cycles(keyCode: keyCode, command: command, control: control, option: option, titleFocused: titleFocused)
        }
        expect(cycles(), "⌃e cycles in the title field")
        expect(!cycles(titleFocused: false), "no class key outside the title field")
        expect(!cycles(control: false), "plain e types")
        expect(!cycles(command: true) && !cycles(option: true), "⌘⌃e and ⌥⌃e are other keys")
        expect(!cycles(keyCode: 15), "⌃r is not the class key")
        expect(Keymap.NewSession.cycleClass.keyCodes == [14] && Keymap.NewSession.cycleClass.modifiers == [.control], "⌃e is the e key with control")
    }

    private static func editPortraitIsEditableForMastersOnly() {
        func portrait(role: String, sessionClass: String = "cleric") -> EditSessionPortrait {
            EditSessionPortrait(session: TrackerSession(id: "qm-1", title: "t", repoName: "r", sessionClass: sessionClass, role: role))
        }
        let master = portrait(role: "master")
        expect(master == .choosing(.cleric) && master.isEditable, "a master's class is editable")
        expect(master.label == "Cleric" && master.portrait == .master(.cleric), "a master shows its class portrait and name")
        let worker = portrait(role: "worker")
        expect(worker == .familiar(.cleric) && !worker.isEditable, "a worker's familiar is read-only")
        expect(worker.label == nil && worker.portrait == .familiar(.cleric), "a worker shows its familiar and no subtext")
        expect(portrait(role: "shell") == .none && portrait(role: "shell").portrait == nil, "a shell has no portrait row")
        for role in ["shell", "tmux", "orphan"] {
            for sessionClass in ["", "cleric"] {
                expect(portrait(role: role, sessionClass: sessionClass) == .none, "a \(role) row has no portrait row, whatever its class is: \(sessionClass)")
            }
        }
        expect(portrait(role: "worker", sessionClass: "") == .none, "a worker whose master's class is unknown has no familiar to show")
    }

    private static func editPortraitCyclesTheMastersClassAndLeavesTheRestAlone() {
        var master = EditSessionPortrait.choosing(.bard)
        master.cycle()
        expect(master == .choosing(.paladin), "an edit has no Random: bard wraps to paladin")
        master.cycle()
        expect(master.label == "Wizard", "the label follows the class")
        var worker = EditSessionPortrait.familiar(.druid)
        worker.cycle()
        expect(worker == .familiar(.druid), "⌃e and a click do nothing on a familiar")
        var none = EditSessionPortrait.none
        none.cycle()
        expect(none == .none, "nothing to cycle without a portrait")
    }

    private static func editSavesAReclassOnlyWhenTheClassChanged() {
        do {
            let initial = EditSessionPortrait.choosing(.cleric)
            let unchanged = try initial.reclassRequest(sessionID: "qm-1", since: initial)
            expect(unchanged == nil, "an unchanged class saves no reclass")
            var edited = initial
            edited.cycle()
            let changed = try edited.reclassRequest(sessionID: "qm-1", since: initial)
            expect(changed?.method == "reclass" && changed?.data["class"] == "bard", "a changed class saves a reclass: \(String(describing: changed))")
            var lap = initial
            for _ in 0..<SessionClass.allCases.count {
                lap.cycle()
            }
            let roundTrip = try lap.reclassRequest(sessionID: "qm-1", since: initial)
            expect(roundTrip == nil, "cycling all the way round is no change")
            let worker = try EditSessionPortrait.familiar(.druid).reclassRequest(sessionID: "qm-2", since: .familiar(.wizard))
            expect(worker == nil, "a worker never reclasses")
            let shell = try EditSessionPortrait.none.reclassRequest(sessionID: "qm-3", since: .none)
            expect(shell == nil, "a shell never reclasses")
        } catch {
            fail("reclassRequest threw \(error)")
        }
    }

    /// A master the backfill hasn't reached has no class, but it is still a master: its row is decided by its role.
    private static func anUnassignedMasterIsEditableAndStartsAtThePaladin() {
        for sessionClass in ["", "ranger"] {
            let session = TrackerSession(id: "qm-1", title: "t", repoName: "r", sessionClass: sessionClass, role: "master")
            var portrait = EditSessionPortrait(session: session)
            let initial = portrait
            expect(portrait == .choosing(nil) && portrait.isEditable, "a master with class \"\(sessionClass)\" is editable")
            expect(portrait.portrait == .master(nil) && portrait.label == "Random", "it shows the Random silhouette and the \"Random\" segment")
            expect(portrait.portrait?.resourceName == "random", "the silhouette is the Random image")
            do {
                let unchanged = try portrait.reclassRequest(sessionID: "qm-1", since: initial)
                expect(unchanged == nil, "an unchanged save sends no reclass")
                portrait.cycle()
                expect(portrait == .choosing(.paladin) && portrait.label == "Paladin", "the first cycle picks paladin, not Random")
                let request = try portrait.reclassRequest(sessionID: "qm-1", since: initial)
                expect(request?.method == "reclass" && request?.data["session_id"] == "qm-1" && request?.data["class"] == "paladin", "a save after a cycle sends the reclass: \(String(describing: request))")
                for _ in 0..<SessionClass.allCases.count {
                    portrait.cycle()
                }
                expect(portrait == .choosing(.paladin), "after bard it wraps to paladin: an edit has no Random to return to")
            } catch {
                fail("reclassRequest threw \(error)")
            }
        }
    }

    private static func editPortraitNamesItselfForAssistiveTechnology() {
        expect(EditSessionPortrait.choosing(.cleric).accessibilityLabel == "Class Cleric", "a master's portrait names its class")
        expect(EditSessionPortrait.choosing(nil).accessibilityLabel == "Class Random", "an unassigned master's portrait says Random")
        expect(EditSessionPortrait.familiar(.druid).accessibilityLabel == "Druid familiar", "a worker's portrait names its familiar")
        expect(EditSessionPortrait.none.accessibilityLabel == nil, "no portrait, no label")
    }

    private static func startRequestEncodesAClassOnlyWhenChosen() {
        do {
            let random = try ServeMutationRequests.start(title: nil, cwd: "/tmp/project", agent: "claude", color: "", prompt: nil)
            expect(random.data["class"] == nil, "Random sends no class, so the backend picks")
            let chosen = try ServeMutationRequests.start(title: nil, cwd: "/tmp/project", agent: "claude", color: "", prompt: nil, sessionClass: .rogue)
            expect(chosen.method == "start" && chosen.data["class"] == "rogue", "a chosen class is sent by its id")
        } catch {
            fail("start request threw \(error)")
        }
    }

    private static func reclassRequestEncodesTheSessionAndClass() {
        do {
            let request = try ServeMutationRequests.reclass(sessionID: " qm-1 ", to: .barbarian)
            let object = request.jsonObject(id: "reclass") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(object["method"] as? String == "reclass", "the method is reclass")
            expect(data?["session_id"] as? String == "qm-1" && data?["class"] as? String == "barbarian", "the session id and the class id")
            do {
                _ = try ServeMutationRequests.reclass(sessionID: " ", to: .bard)
                fail("a reclass needs a session id")
            } catch let error as ServeMutationRequestError {
                expect(error == .missing("session_id"), "a missing session id is named")
            }
        } catch {
            fail("reclass request threw \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("SessionClassLogicTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }
}
