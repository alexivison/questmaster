import Foundation
import QuestmasterCore

struct RuntimeStoreTests {
    static func run() {
        initialStateReflectsConstructorArguments()
        applyMergesUpdateAndNotifies()
        serveConnectionStateNotifiesOnlyOnChange()
        terminalSessionNotifiesOnlyOnChange()
        terminalSessionSelectionsPersist()
        cancelledObserverStopsReceivingNotifications()
        print("RuntimeStoreTests: all tests passed")
    }

    private static func initialStateReflectsConstructorArguments() {
        let store = RuntimeStore(sourceLabel: "label", currentTerminalSessionID: "qm-1")
        expect(store.snapshot.sourceLabel == "label", "source label not stored")
        expect(store.serveConnectionState == .starting, "default state should be starting")
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

    private static func serveConnectionStateNotifiesOnlyOnChange() {
        let store = RuntimeStore(sourceLabel: "label")
        var notifications = 0
        let token = store.observe { notifications += 1 }
        store.setServeConnectionState(.ready)
        store.setServeConnectionState(.ready)
        expect(store.serveConnectionState == .ready, "state not updated")
        expect(notifications == 1, "redundant state change should not notify")
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

    private static func terminalSessionSelectionsPersist() {
        let suiteName = "QuestmasterRuntimeStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("RuntimeStoreTests failed: could not create defaults suite\n", stderr)
            Foundation.exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = RuntimeStore(
            sourceLabel: "label",
            currentTerminalSessionID: "qm-1",
            lastSessionDefaults: defaults
        )
        store.setCurrentTerminalSessionID("qm-1")
        expect(
            LastSessionPreference.storedSessionID(in: defaults) == "qm-1",
            "unchanged terminal selection should still persist"
        )
        store.setCurrentTerminalSessionID(" qm-2 ")
        expect(
            LastSessionPreference.storedSessionID(in: defaults) == "qm-2",
            "changed terminal selection should persist"
        )
        store.setCurrentTerminalSessionID(nil)
        expect(
            LastSessionPreference.storedSessionID(in: defaults) == nil,
            "nil terminal selection should clear persisted id"
        )
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
