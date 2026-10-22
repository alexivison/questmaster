import Foundation
import QuestmasterCore

struct ModalCommandRoutingTests {
    static func run() {
        everyCommandOpensWhenNoModalIsOpen()
        theQuestLogsToggleOnlyActsWhenItIsOnTop()
        newQuestOpensAsTheQuestLogsChild()
        otherCommandsAreIgnoredWhileAModalIsOpen()
        print("ModalCommandRoutingTests: all tests passed")
    }

    private static func everyCommandOpensWhenNoModalIsOpen() {
        for command in GlobalModalCommand.allCases {
            expect(ModalCommandRouting.route(command, top: nil) == .allowed, "\(command) should open when no modal is open")
        }
    }

    private static func theQuestLogsToggleOnlyActsWhenItIsOnTop() {
        expect(ModalCommandRouting.route(.toggleQuestLog, top: .questLog) == .allowed, "the toggle should close the Quest Log on top")
        expect(ModalCommandRouting.route(.toggleQuestLog, top: .other) == .ignored, "the toggle should do nothing under another modal")
    }

    private static func newQuestOpensAsTheQuestLogsChild() {
        expect(ModalCommandRouting.route(.newQuest, top: .questLog) == .child, "New Quest over the Quest Log should open as its child")
        expect(ModalCommandRouting.route(.newQuest, top: .other) == .ignored, "New Quest over another modal should be ignored")
    }

    private static func otherCommandsAreIgnoredWhileAModalIsOpen() {
        let others: [GlobalModalCommand] = [.newSession, .settings, .editSession, .editRepo, .deleteSession]
        for command in others {
            for top in [ModalKind.questLog, .other] {
                expect(ModalCommandRouting.route(command, top: top) == .ignored, "\(command) over \(top) should be ignored")
            }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
