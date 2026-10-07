import Foundation

public enum RightDockWidthMode: Equatable {
    case standard
    case compact
}

public struct ShellSplitLayoutMetrics: Equatable {
    /// Vertical inset for the tracker/dock side cards, and the horizontal gap on the dock's
    /// outer (window-facing) edge only — its terminal-facing edge sits flush, with Ghostty's own
    /// padding providing the visible gap there. The tracker's own horizontal gaps are
    /// `trackerLeadingInset`/`trackerTrailingGap` below, so its two sides can differ from the dock's.
    public let sideCardInset: Double
    public let dockDividerHitWidth: Double
    public let trackerMaxWidth: Double
    /// Window edge to the tracker plates.
    public let trackerLeadingInset: Double
    /// Tracker plates to the terminal pane.
    public let trackerTrailingGap: Double
    /// Height reserved at the window's bottom for a footer drawn outside this layout (the action
    /// bar) — the tracker and terminal frames stop above it. The dock (and its resize divider)
    /// ignore it and keep the full window height with `sideCardInset` top and bottom, as they did
    /// before any footer existed; it's drawn on top of the dock there, not sharing its space.
    public let footerReservedHeight: Double

    public init(
        sideCardInset: Double,
        dockDividerHitWidth: Double,
        trackerMaxWidth: Double,
        trackerLeadingInset: Double,
        trackerTrailingGap: Double,
        footerReservedHeight: Double = 0
    ) {
        self.sideCardInset = sideCardInset
        self.dockDividerHitWidth = dockDividerHitWidth
        self.trackerMaxWidth = trackerMaxWidth
        self.trackerLeadingInset = trackerLeadingInset
        self.trackerTrailingGap = trackerTrailingGap
        self.footerReservedHeight = footerReservedHeight
    }
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

    public var maxY: Double {
        y + height
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
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool,
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode
    ) -> ShellSplitLayout? {
        guard size.width > 0 else {
            return nil
        }

        let availableWidth = max(0, size.width - sideCardHorizontalInsets(
            metrics: metrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(metrics.trackerMaxWidth, availableWidth) : 0
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

        // NSView frames are non-flipped (y=0 is the window's bottom edge): the reserved footer
        // height has to sit BELOW the pane area, so the tracker/terminal/divider's own y origin
        // starts above it, at `paneAreaY`, not at the window's absolute bottom. The dock (and its
        // divider) don't reserve for it and keep the full window height, same as before any
        // footer existed — it draws on top of the dock there instead of sharing its space.
        let paneAreaY = metrics.footerReservedHeight
        let paneAreaHeight = max(0, size.height - metrics.footerReservedHeight)
        let paneSideCardY = paneAreaY + metrics.sideCardInset
        let paneSideCardHeight = max(0, paneAreaHeight - (metrics.sideCardInset * 2))
        let dockSideCardY = metrics.sideCardInset
        let dockSideCardHeight = max(0, size.height - (metrics.sideCardInset * 2))
        var x = 0.0
        let trackerFrame: ShellSplitRect
        let firstDividerFrame: ShellSplitRect
        if trackerVisible {
            trackerFrame = ShellSplitRect(
                x: metrics.trackerLeadingInset,
                y: paneSideCardY,
                width: trackerWidth,
                height: paneSideCardHeight
            )
            x = trackerFrame.maxX + metrics.trackerTrailingGap
            firstDividerFrame = ShellSplitRect(x: trackerFrame.maxX, y: paneSideCardY, width: 0, height: paneSideCardHeight)
        } else {
            trackerFrame = ShellSplitRect(x: 0, y: paneSideCardY, width: 0, height: paneSideCardHeight)
            firstDividerFrame = ShellSplitRect(x: 0, y: 0, width: 0, height: 0)
        }

        let terminalFrame = ShellSplitRect(x: x, y: paneAreaY, width: terminalWidth, height: paneAreaHeight)
        x += terminalWidth

        let secondDividerFrame: ShellSplitRect
        let dockFrame: ShellSplitRect
        if dockVisible {
            // Flush against the terminal pane — Ghostty's own padding alone provides the gap
            // there; `sideCardInset` now only guards the dock's outer (window-facing) edge.
            let dockCardMinX = x
            secondDividerFrame = ShellSplitRect(
                x: dockCardMinX - (metrics.dockDividerHitWidth / 2),
                y: dockSideCardY,
                width: metrics.dockDividerHitWidth,
                height: dockSideCardHeight
            )
            dockFrame = ShellSplitRect(
                x: dockCardMinX,
                y: dockSideCardY,
                width: dockWidth,
                height: dockSideCardHeight
            )
        } else {
            secondDividerFrame = ShellSplitRect(x: size.width, y: dockSideCardY, width: 0, height: dockSideCardHeight)
            dockFrame = ShellSplitRect(x: size.width, y: dockSideCardY, width: 0, height: dockSideCardHeight)
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
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool
    ) -> Double {
        guard dockVisible else {
            return startWidth
        }
        let availableWidth = max(0, windowWidth - sideCardHorizontalInsets(
            metrics: metrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(metrics.trackerMaxWidth, availableWidth) : 0
        return DockWidthPreference.clampedWidth(
            startWidth - deltaX,
            availableWidth: availableWidth,
            trackerWidth: trackerWidth
        )
    }

    private static func sideCardHorizontalInsets(
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool
    ) -> Double {
        let trackerInsets = trackerVisible ? metrics.trackerLeadingInset + metrics.trackerTrailingGap : 0
        // Only the dock's outer (window-facing) edge reserves `sideCardInset` — its terminal-facing
        // edge is flush, with Ghostty's own padding providing the visible gap there.
        let dockInsets = dockVisible ? metrics.sideCardInset : 0
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
