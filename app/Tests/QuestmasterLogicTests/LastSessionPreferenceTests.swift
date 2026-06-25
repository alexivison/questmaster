import Foundation
import QuestmasterCore

struct LastSessionPreferenceTests {
    static func run() {
        persistenceRoundTripsSessionIDs()
        emptyValuesClearThePreference()
        print("LastSessionPreferenceTests: all tests passed")
    }

    private static func persistenceRoundTripsSessionIDs() {
        withDefaults { defaults in
            expect(LastSessionPreference.storedSessionID(in: defaults) == nil, "empty defaults should not have a session id")
            LastSessionPreference.store(sessionID: " qm-worker \n", in: defaults)
            expect(
                LastSessionPreference.storedSessionID(in: defaults) == "qm-worker",
                "stored session id should trim whitespace and round trip"
            )
        }
    }

    private static func emptyValuesClearThePreference() {
        withDefaults { defaults in
            LastSessionPreference.store(sessionID: "qm-worker", in: defaults)
            LastSessionPreference.store(sessionID: "", in: defaults)
            expect(LastSessionPreference.storedSessionID(in: defaults) == nil, "empty session id should clear stored id")

            LastSessionPreference.store(sessionID: "qm-worker", in: defaults)
            LastSessionPreference.store(sessionID: nil, in: defaults)
            expect(LastSessionPreference.storedSessionID(in: defaults) == nil, "nil session id should clear stored id")
        }
    }

    private static func withDefaults(_ block: (UserDefaults) -> Void) {
        let suiteName = "QuestmasterLastSessionPreferenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("LastSessionPreferenceTests failed: could not create defaults suite\n", stderr)
            Foundation.exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        block(defaults)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("LastSessionPreferenceTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
