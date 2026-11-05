import Foundation
import QuestmasterCore

struct ConnectionStateTests {
    static func run() {
        theWaitForAFirstTrackerOutlastsItsWindow()
        aLostConnectionAfterATrackerReconnects()
        anIncompatibleBackendHoldsUntilATrackerDecodes()
        eachStateTellsTheTrackerWhatToDraw()
        aReconnectKeepsTheLastTracker()
        anIncompatibleBackendEmptiesTheTracker()
        aLocalEditKeepsTheConnectionState()
        aStoreFedDirectlyStartsConnected()
        print("ConnectionStateTests: all tests passed")
    }

    private static func theWaitForAFirstTrackerOutlastsItsWindow() {
        var machine = ConnectionStateMachine()
        expect(machine.state == .connecting, "a new connection should start connecting")
        machine.lost(after: 4.9)
        expect(machine.state == .connecting, "a failure inside the waiting window should still read as connecting")
        machine.lost(after: ConnectionState.waitingWindow)
        expect(machine.state == .unavailable, "a failure past the waiting window should read as unavailable")
    }

    private static func aLostConnectionAfterATrackerReconnects() {
        var machine = ConnectionStateMachine()
        machine.receivedTracker()
        expect(machine.state == .connected, "a tracker should make the connection live")
        machine.lost(after: 0.1)
        expect(machine.state == .reconnecting, "a drop after a tracker should reconnect")
        machine.lost(after: 3_600)
        expect(machine.state == .reconnecting, "a long reconnect should keep the last tracker, not read as unavailable")
        machine.receivedTracker()
        expect(machine.state == .connected, "a fresh tracker should make the connection live again")
    }

    private static func anIncompatibleBackendHoldsUntilATrackerDecodes() {
        var machine = ConnectionStateMachine()
        machine.receivedTracker()
        machine.incompatible("expected protocol_version 3, got 1")
        expect(machine.isIncompatible, "a mismatch should make the backend incompatible")
        machine.lost(after: 0.1)
        machine.lost(after: 60)
        expect(machine.state == .incompatible("expected protocol_version 3, got 1"), "drops and failed connects should not hide the mismatch, got \(machine.state)")
        machine.receivedTracker()
        expect(machine.state == .connected && !machine.isIncompatible, "a tracker that decodes should end the mismatch")
    }

    private static func eachStateTellsTheTrackerWhatToDraw() {
        let states: [ConnectionState] = [.connecting, .unavailable, .connected, .reconnecting, .incompatible("got 1")]
        expect(states.filter(\.awaitsFirstTracker) == [.connecting, .unavailable], "only the wait for a first tracker draws the skeleton")
        expect(states.filter(\.showsLastTracker) == [.reconnecting], "only a reconnect shows the last tracker")
        expect(states.compactMap(\.blockingMessage) == ["incompatible backend: got 1"], "only an incompatible backend blocks the tracker with a message")
    }

    private static func aReconnectKeepsTheLastTracker() {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.apply(RuntimeUpdate(tracker: tracker("qm-old"), connection: .connected))
        let tick = snapshot.tick

        expect(snapshot.apply(RuntimeUpdate(connection: .reconnecting)), "a reconnect should change the snapshot")
        expect(sessionIDs(snapshot) == ["qm-old"], "a reconnect should keep the last tracker, got \(sessionIDs(snapshot))")
        expect(snapshot.connection.showsLastTracker && snapshot.tick == tick + 1, "the snapshot should know its tracker is the last one")

        snapshot.apply(RuntimeUpdate(tracker: tracker("qm-new"), connection: .connected))
        expect(sessionIDs(snapshot) == ["qm-new"] && snapshot.connection == .connected, "a fresh tracker should replace the last one")
    }

    private static func anIncompatibleBackendEmptiesTheTracker() {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.apply(RuntimeUpdate(tracker: tracker("qm-old"), connection: .connected))
        snapshot.apply(RuntimeUpdate(connection: .incompatible("got 1")))
        expect(sessionIDs(snapshot).isEmpty, "an incompatible backend's tracker should not show")
        expect(snapshot.connection.blockingMessage == "incompatible backend: got 1", "the tracker should show the incompatible message")
    }

    private static func aLocalEditKeepsTheConnectionState() {
        let store = RuntimeStore(sourceLabel: "test")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [], quests: [QuestItem(id: "qst-1", content: "One")]), connection: .connected))
        store.apply(RuntimeUpdate(connection: .reconnecting))
        store.removeQuest(id: "qst-1")
        expect(store.snapshot.tracker.quests.isEmpty, "the acknowledged deletion should apply")
        expect(store.snapshot.connection == .reconnecting, "a local edit should not make the connection live")
    }

    private static func aStoreFedDirectlyStartsConnected() {
        let store = RuntimeStore(sourceLabel: "test")
        expect(store.snapshot.connection == .connected, "a store without a runtime connection should draw what it is given")
    }

    private static func tracker(_ sessionID: String) -> TrackerSnapshot {
        TrackerSnapshot(repos: [TrackerRepo(id: "example-app", name: "example-app", sessions: [
            TrackerSession(id: sessionID, title: "Session", repoName: "example-app"),
        ])])
    }

    private static func sessionIDs(_ snapshot: RuntimeSnapshot) -> [String] {
        snapshot.tracker.repos.flatMap(\.sessions).map(\.id)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ConnectionStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
