import AppKit
import QuestmasterCore

enum TrafficLightPositioner {
    static func position(in window: NSWindow?, navigation: AppNavigationState) {
        guard let window else {
            return
        }
        let targetCenterFromTop = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0)
            + (ShellMetrics.topBarHeight / 2)
        let targetLeading = (navigation.trackerVisible ? ShellMetrics.sideCardInset : 0) + 14
        let closeButton = window.standardWindowButton(.closeButton)
        let horizontalOffset = closeButton.map { targetLeading - $0.frame.minX } ?? 0
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType),
                  let superview = button.superview else {
                continue
            }
            var frame = button.frame
            let centerY = superview.isFlipped
                ? targetCenterFromTop
                : superview.bounds.height - targetCenterFromTop
            frame.origin.y = centerY - frame.height / 2
            frame.origin.x += horizontalOffset
            button.frame = frame
        }
    }
}
