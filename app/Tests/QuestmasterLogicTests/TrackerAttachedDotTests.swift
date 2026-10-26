import Foundation
import QuestmasterCore

struct TrackerAttachedDotTests {
    static func run() {
        theAttachedMasterCarriesTheDot()
        anExpandedWorkerCarriesItsOwnDot()
        aCollapsedWorkerPutsTheDotOnItsMaster()
        anAttachedShellHasNoDot()
        nothingAttachedHasNoDot()
        anUnlistedSessionHasNoDot()
        print("TrackerAttachedDotTests: all tests passed")
    }

    /// The plates of a small tracker: `a` has collapsed its workers `a-w1` and `a-w2`; `b` is expanded, so its worker
    /// `b-w` has a plate of its own. `sh` is a shell, which has no plate.
    private static let plates: [(id: String, collapsedWorkerIDs: [String])] = [
        ("a", ["a-w1", "a-w2"]),
        ("b", []),
        ("b-w", []),
    ]

    /// The ids of the plates that carry the dot for `attachedID`.
    private static func carriers(_ attachedID: String?) -> [String] {
        plates.filter {
            TrackerAttachedDot.isShown(onPlate: $0.id, collapsedWorkerIDs: $0.collapsedWorkerIDs, attachedID: attachedID)
        }.map(\.id)
    }

    private static func theAttachedMasterCarriesTheDot() {
        expect(carriers("a") == ["a"], "an attached master should carry the dot, got \(carriers("a"))")
        expect(carriers("b") == ["b"], "an attached expanded master should carry the dot, and not its worker, got \(carriers("b"))")
    }

    private static func anExpandedWorkerCarriesItsOwnDot() {
        expect(carriers("b-w") == ["b-w"], "an attached expanded worker should carry the dot, and not its master, got \(carriers("b-w"))")
    }

    private static func aCollapsedWorkerPutsTheDotOnItsMaster() {
        expect(carriers("a-w1") == ["a"], "a collapsed worker's dot should go on its master, got \(carriers("a-w1"))")
        expect(carriers("a-w2") == ["a"], "a collapsed worker's dot should go on its master, got \(carriers("a-w2"))")
    }

    private static func anAttachedShellHasNoDot() {
        expect(carriers("sh").isEmpty, "an attached shell should have no dot, got \(carriers("sh"))")
    }

    private static func nothingAttachedHasNoDot() {
        expect(carriers(nil).isEmpty, "nothing attached should show no dot")
        expect(carriers("").isEmpty, "an empty id should show no dot")
        expect(carriers("  \n").isEmpty, "a blank id should show no dot")
    }

    private static func anUnlistedSessionHasNoDot() {
        expect(carriers("gone").isEmpty, "a session the tracker doesn't list should show no dot, got \(carriers("gone"))")
        // A padded id is the same id: ids are cleaned the way the rest of the tracker cleans them.
        expect(carriers(" a-w1\n") == ["a"], "an attached id should be cleaned before matching, got \(carriers(" a-w1\n"))")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerAttachedDotTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
