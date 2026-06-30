import Foundation

public enum RightDockWidthMode: Equatable {
    case standard
    case compact
}

public enum ShellSplitMetrics {
    public static let topBarHeight = 46.0
    public static let trafficLightReserve = 78.0
    // Core cannot import the App token layer. Keep these in sync with
    // `Token.Spacing.card` and `Token.Radius.card`; App `ShellMetrics` bridges
    // from these values so split layout has one tested source of truth.
    public static let sideCardInset = 8.0
    public static let sideCardCornerRadius = 8.0
    public static let dockDividerHitWidth = 7.0
    public static let trackerMaxWidth = 300.0
}

public struct ShellSplitSize: Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ShellSplitRect: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        x + width
    }

    public var midX: Double {
        x + width / 2
    }

    public var midY: Double {
        y + height / 2
    }

    public var isWholePoint: Bool {
        [x, y, width, height].allSatisfy { $0.rounded() == $0 }
    }
}

public struct ShellSplitLayout: Equatable {
    public let trackerFrame: ShellSplitRect
    public let terminalFrame: ShellSplitRect
    public let dockFrame: ShellSplitRect
    public let firstDividerFrame: ShellSplitRect
    public let secondDividerFrame: ShellSplitRect
    public let dockWidth: Double

    public init(
        trackerFrame: ShellSplitRect,
        terminalFrame: ShellSplitRect,
        dockFrame: ShellSplitRect,
        firstDividerFrame: ShellSplitRect,
        secondDividerFrame: ShellSplitRect,
        dockWidth: Double
    ) {
        self.trackerFrame = trackerFrame
        self.terminalFrame = terminalFrame
        self.dockFrame = dockFrame
        self.firstDividerFrame = firstDividerFrame
        self.secondDividerFrame = secondDividerFrame
        self.dockWidth = dockWidth
    }
}

public enum ShellSplitLayoutPlanner {
    public static func layout(
        size: ShellSplitSize,
        trackerVisible: Bool,
        dockVisible: Bool,
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode
    ) -> ShellSplitLayout? {
        guard size.width > 0 else {
            return nil
        }

        let availableWidth = max(0, size.width - sideCardHorizontalInsets(
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(ShellSplitMetrics.trackerMaxWidth, availableWidth) : 0
        let dockWidth = dockVisible
            ? DockWidthPreference.clampedWidth(
                proposedDockWidth(
                    preferredDockWidth: preferredDockWidth,
                    dockWidthMode: dockWidthMode,
                    windowWidth: size.width
                ),
                availableWidth: availableWidth,
                trackerWidth: trackerWidth
            )
            : 0
        let terminalWidth = max(0, availableWidth - trackerWidth - dockWidth)

        let sideCardY = ShellSplitMetrics.sideCardInset
        let sideCardHeight = max(0, size.height - (ShellSplitMetrics.sideCardInset * 2))
        var x = 0.0
        let trackerFrame: ShellSplitRect
        let firstDividerFrame: ShellSplitRect
        if trackerVisible {
            trackerFrame = ShellSplitRect(
                x: ShellSplitMetrics.sideCardInset,
                y: sideCardY,
                width: trackerWidth,
                height: sideCardHeight
            )
            x = trackerFrame.maxX + ShellSplitMetrics.sideCardInset
            firstDividerFrame = ShellSplitRect(x: trackerFrame.maxX, y: sideCardY, width: 0, height: sideCardHeight)
        } else {
            trackerFrame = ShellSplitRect(x: 0, y: sideCardY, width: 0, height: sideCardHeight)
            firstDividerFrame = ShellSplitRect(x: 0, y: 0, width: 0, height: 0)
        }

        let terminalFrame = ShellSplitRect(x: x, y: 0, width: terminalWidth, height: size.height)
        x += terminalWidth

        let secondDividerFrame: ShellSplitRect
        let dockFrame: ShellSplitRect
        if dockVisible {
            let dockGapX = x
            let dockCardMinX = dockGapX + ShellSplitMetrics.sideCardInset
            secondDividerFrame = ShellSplitRect(
                x: dockCardMinX - (ShellSplitMetrics.dockDividerHitWidth / 2),
                y: sideCardY,
                width: ShellSplitMetrics.dockDividerHitWidth,
                height: sideCardHeight
            )
            dockFrame = ShellSplitRect(
                x: dockCardMinX,
                y: sideCardY,
                width: dockWidth,
                height: sideCardHeight
            )
        } else {
            secondDividerFrame = ShellSplitRect(x: size.width, y: sideCardY, width: 0, height: sideCardHeight)
            dockFrame = ShellSplitRect(x: size.width, y: sideCardY, width: 0, height: sideCardHeight)
        }

        return ShellSplitLayout(
            trackerFrame: pointAligned(trackerFrame),
            terminalFrame: pointAligned(terminalFrame),
            dockFrame: pointAligned(dockFrame),
            firstDividerFrame: pointAligned(firstDividerFrame),
            secondDividerFrame: pointAligned(secondDividerFrame),
            dockWidth: pointAligned(dockWidth)
        )
    }

    public static func resizedDockWidth(
        startWidth: Double,
        deltaX: Double,
        windowWidth: Double,
        trackerVisible: Bool,
        dockVisible: Bool
    ) -> Double {
        guard dockVisible else {
            return startWidth
        }
        let availableWidth = max(0, windowWidth - sideCardHorizontalInsets(
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(ShellSplitMetrics.trackerMaxWidth, availableWidth) : 0
        return DockWidthPreference.clampedWidth(
            startWidth - deltaX,
            availableWidth: availableWidth,
            trackerWidth: trackerWidth
        )
    }

    private static func sideCardHorizontalInsets(trackerVisible: Bool, dockVisible: Bool) -> Double {
        let trackerInsets = trackerVisible ? ShellSplitMetrics.sideCardInset * 2 : 0
        let dockInsets = dockVisible ? ShellSplitMetrics.sideCardInset * 2 : 0
        return trackerInsets + dockInsets
    }

    private static func proposedDockWidth(
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode,
        windowWidth: Double
    ) -> Double {
        switch dockWidthMode {
        case .standard:
            return preferredDockWidth ?? DockWidthPreference.defaultWidth(forWindowWidth: windowWidth)
        case .compact:
            return DockWidthPreference.compactWidth
        }
    }

    private static func pointAligned(_ rect: ShellSplitRect) -> ShellSplitRect {
        ShellSplitRect(
            x: pointAligned(rect.x),
            y: pointAligned(rect.y),
            width: pointAligned(rect.width),
            height: pointAligned(rect.height)
        )
    }

    private static func pointAligned(_ value: Double) -> Double {
        value.rounded()
    }
}
