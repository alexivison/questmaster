import Foundation
import QuestmasterCore

struct DockWidthPreferenceTests {
    static func run() {
        panelsAndViewerAreShareOfTheWindow()
        clampPreservesTerminalAndDockMinimums()
        widthsRoundToWholePoints()
        persistenceRoundTripsPositiveFractions()
        print("DockWidthPreferenceTests: all tests passed")
    }

    private static func panelsAndViewerAreShareOfTheWindow() {
        expect(DockWidthPreference.panelWidth(forWindowWidth: 1512) == 360, "panels keep the 360 minimum on a small window")
        expect(DockWidthPreference.panelWidth(forWindowWidth: 2560) == 512, "panels take 20% of the window")
        expect(DockWidthPreference.viewerWidth(fraction: nil, windowWidth: 2560) == 768, "the viewer takes 30% by default")
        expect(DockWidthPreference.viewerWidth(fraction: 0.5, windowWidth: 2560) == 1280, "the viewer takes the user's share")
        expect(DockWidthPreference.viewerWidth(fraction: 0.1, windowWidth: 2560) == 512, "the viewer is never narrower than the panels")
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

    private static func widthsRoundToWholePoints() {
        expect(
            DockWidthPreference.clampedWidth(640.5, availableWidth: 1518, trackerWidth: 300) == 641,
            "clamped dock width should round fractional resize values"
        )
    }

    private static func persistenceRoundTripsPositiveFractions() {
        let suiteName = "QuestmasterDockWidthPreferenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("DockWidthPreferenceTests failed: could not create defaults suite\n", stderr)
            Foundation.exit(1)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        expect(DockWidthPreference.storedFraction(in: defaults) == nil, "empty defaults should not have a dock share")
        DockWidthPreference.store(fraction: 0.35, in: defaults)
        expect(DockWidthPreference.storedFraction(in: defaults) == 0.35, "stored dock share did not round trip")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("DockWidthPreferenceTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
