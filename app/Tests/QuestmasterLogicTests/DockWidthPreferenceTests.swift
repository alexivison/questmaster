import Foundation
import QuestmasterCore

struct DockWidthPreferenceTests {
    static func run() {
        defaultWidthIsWiderThanLegacyFixedWidth()
        clampPreservesTerminalAndDockMinimums()
        persistenceRoundTripsPositiveWidths()
        print("DockWidthPreferenceTests: all tests passed")
    }

    private static func defaultWidthIsWiderThanLegacyFixedWidth() {
        expect(
            DockWidthPreference.defaultWidth(forWindowWidth: 1520) == 640,
            "default dock width should use the wider fixed default at the app's default window width"
        )
        expect(
            DockWidthPreference.defaultWidth(forWindowWidth: 2000) == 800,
            "default dock width should scale to 40 percent on wider windows"
        )
    }

    private static func clampPreservesTerminalAndDockMinimums() {
        expect(
            DockWidthPreference.clampedWidth(200, availableWidth: 1518, trackerWidth: 300) == 360,
            "dock width should clamp to the dock minimum"
        )
        expect(
            DockWidthPreference.clampedWidth(1000, availableWidth: 1518, trackerWidth: 300) == 858,
            "dock width should leave the minimum terminal width"
        )
        expect(
            DockWidthPreference.clampedWidth(640, availableWidth: 800, trackerWidth: 300) == 140,
            "dock width should degrade when the window cannot fit both minimums"
        )
    }

    private static func persistenceRoundTripsPositiveWidths() {
        let suiteName = "QuestmasterDockWidthPreferenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("DockWidthPreferenceTests failed: could not create defaults suite\n", stderr)
            Foundation.exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        expect(DockWidthPreference.storedWidth(in: defaults) == nil, "empty defaults should not have a dock width")
        DockWidthPreference.store(width: 512, in: defaults)
        expect(DockWidthPreference.storedWidth(in: defaults) == 512, "stored dock width did not round trip")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("DockWidthPreferenceTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
