import Foundation
import QuestmasterCore

struct RuntimeStoreTests {
    static func run() {
        initialStateReflectsConstructorArguments()
        applyMergesUpdateAndNotifies()
        identicalApplyDoesNotNotifyOrTick()
        terminalSessionNotifiesOnlyOnChange()
        cancelledObserverStopsReceivingNotifications()
        print("RuntimeStoreTests: all tests passed")
    }

    private static func initialStateReflectsConstructorArguments() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        expect(store.snapshot.sourceLabel == "label", "source label not stored")
        expect(store.currentTerminalSessionID == "qm-1", "terminal id not stored")
        expect(store.snapshot.tick == 0, "fresh snapshot should start at tick 0")
    }

    private static func applyMergesUpdateAndNotifies() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(.serveUnavailable("serve down"))
        expect(notifications == 1, "apply did not notify observer")
        expect(store.snapshot.observedLabel == "serve down", "apply did not merge update")
        expect(store.snapshot.tick == 1, "apply did not advance tick")
        token.cancel()
    }

    private static func identicalApplyDoesNotNotifyOrTick() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        let update = RuntimeUpdate.serveUnavailable("serve down")
        store.apply(update)
        let tick = store.snapshot.tick
        store.apply(update)
        expect(notifications == 1, "identical apply should notify only once")
        expect(store.snapshot.tick == tick, "identical apply should not advance tick")
        token.cancel()
    }

    private static func terminalSessionNotifiesOnlyOnChange() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.setCurrentTerminalSessionID("qm-1")
        expect(notifications == 0, "unchanged terminal id should not notify")
        store.setCurrentTerminalSessionID("qm-2")
        expect(store.currentTerminalSessionID == "qm-2", "terminal id not updated")
        expect(notifications == 1, "terminal id change should notify once")
        token.cancel()
    }

    private static func cancelledObserverStopsReceivingNotifications() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.apply(.serveUnavailable("one"))
        token.cancel()
        store.apply(.serveUnavailable("two"))
        expect(notifications == 1, "cancelled observer kept receiving notifications")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("RuntimeStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
