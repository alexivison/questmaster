import Foundation
import QuestmasterCore

struct AttachGenerationTests {
    static func run() {
        var generation = AttachGeneration()
        let first = generation.request()
        let second = generation.request()
        expect(!generation.accepts(first), "a newer request must invalidate an older completion")
        expect(generation.accepts(second), "the newest request must be accepted")

        generation.stop()
        expect(!generation.accepts(second), "stop must invalidate pending work")
        let third = generation.request()
        generation.detach()
        expect(!generation.accepts(third), "detach must invalidate pending work")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
